"""Sincroniza producción D-6 de Oracle hacia el staging privado de Supabase.

Ejecutar solo desde la red interna. El guard rechaza toda sentencia que no sea SELECT/WITH
y abre una transacción Oracle READ ONLY. No imprime secretos ni datos de clientes.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import sys
from decimal import Decimal
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Falta la variable de entorno {name}")
    return value


def only_read(statement: str) -> str:
    normalized = statement.strip().upper()
    if not normalized.startswith(("SELECT", "WITH")) or ";" in normalized.rstrip(";"):
        raise RuntimeError("El conector solo permite una sentencia SELECT o WITH")
    return statement


def conectar_oracle():
    """Conexion de solo lectura por SID. Si la base usa un verificador de clave antiguo
    (DPY-3015), defina ORACLE_CLIENT_DIR para usar el modo thick con Instant Client."""
    import oracledb

    if os.getenv("ORACLE_CLIENT_DIR"):
        try:
            oracledb.init_oracle_client(lib_dir=os.environ["ORACLE_CLIENT_DIR"])
        except oracledb.ProgrammingError:
            pass  # ya inicializado
    params = oracledb.ConnectParams(host=env("ORACLE_HOST"), port=int(os.getenv("ORACLE_PORT", "1521")), sid=env("ORACLE_SID"))
    conexion = oracledb.connect(user=env("ORACLE_USER"), password=env("ORACLE_PASSWORD"), params=params)
    conexion.cursor().execute("SET TRANSACTION READ ONLY")
    return conexion


def json_default(value):
    # Como texto: un float pierde centavos en montos grandes. Postgres lo lee como numeric.
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    raise TypeError(f"No se puede serializar {type(value)!r}")


class Supabase:
    def __init__(self):
        self.url = env("SUPABASE_URL").rstrip("/")
        self.key = env("SUPABASE_SERVICE_ROLE_KEY")

    def request(self, method: str, path: str, payload=None, prefer=None):
        headers = {"apikey": self.key, "Authorization": f"Bearer {self.key}", "Content-Type": "application/json"}
        if prefer:
            headers["Prefer"] = prefer
        body = json.dumps(payload, default=json_default).encode() if payload is not None else None
        request = Request(f"{self.url}/rest/v1/{path}", data=body, headers=headers, method=method)
        try:
            with urlopen(request, timeout=45) as response:
                content = response.read().decode()
                return json.loads(content) if content else None
        except HTTPError as error:
            detail = error.read().decode(errors="replace")[:500]
            raise RuntimeError(f"Supabase {method} {path}: {error.code} {detail}") from error

    def create_run(self, since_year: int):
        result = self.request("POST", "oracle_sync_runs_d6", {
            "fuente": "CIE_TRASLADO_MES", "ventana_desde": f"{since_year}-01-01", "estado": "INICIADO",
        }, "return=representation")
        return result[0]["id"]

    def finish_run(self, run_id: str, read_count: int, applied_count: int, checksum: str, error: str | None = None):
        state = "FALLIDO" if error else "COMPLETO"
        path = f"oracle_sync_runs_d6?id=eq.{run_id}"
        self.request("PATCH", path, {"estado": state, "filas_leidas": read_count, "filas_aplicadas": applied_count, "checksum": checksum, "error_resumido": error}, "return=minimal")

    def upsert_staging(self, records):
        if records:
            self.request("POST", "oracle_d6_staging?on_conflict=fuente,source_key", records, "resolution=merge-duplicates,return=minimal")


SQL_CIE_D6 = only_read("""
SELECT ANIO, MES, RAMO, FIANZA, ENDOSO, CLASE, COD_CONTACTO_CLIENTE,
       COD_CONTACTO_BENEFICIARIO, MONTO_AFIANZADO, PRIMA, PRIMA_ANUAL,
       FECHA_EMISION, VIGENCIA_DESDE, VIGENCIA_HASTA, STATUS, ESTADO, TIPO_ENDOSO
FROM main_fusa.CIE_TRASLADO_MES
WHERE CLASE = 'D-6' AND ANIO >= :from_year
ORDER BY ANIO, MES, FIANZA, ENDOSO
""")


def read_oracle(from_year: int):
    with conectar_oracle() as connection:
        cursor = connection.cursor()
        cursor.execute(SQL_CIE_D6, {"from_year": from_year})
        columns = [column[0].lower() for column in cursor.description]
        for row in cursor:
            yield dict(zip(columns, row))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--from-year", type=int, default=dt.date.today().year - 1)
    args = parser.parse_args()
    supabase = Supabase()
    run_id = supabase.create_run(args.from_year)
    read_count = applied_count = 0
    digest = hashlib.sha256()
    batch = []
    try:
        for payload in read_oracle(args.from_year):
            source_key = f"{payload['anio']}-{payload['mes']}-{payload['fianza']}-{payload['endoso']}"
            serialized = json.dumps(payload, default=json_default, sort_keys=True, separators=(",", ":"))
            digest.update(serialized.encode())
            batch.append({
                "sync_run_id": run_id, "fuente": "CIE_TRASLADO_MES", "source_key": source_key,
                "periodo": f"{payload['anio']}-{int(payload['mes']):02d}-01", "payload": payload,
                "source_updated_at": payload.get("fecha_emision"),
            })
            read_count += 1
            if len(batch) == 250:
                supabase.upsert_staging(batch)
                applied_count += len(batch)
                batch.clear()
        supabase.upsert_staging(batch)
        applied_count += len(batch)
        supabase.finish_run(run_id, read_count, applied_count, digest.hexdigest())
        print(f"Oracle D-6: leídas={read_count}, aplicadas={applied_count}")
    except Exception as error:
        supabase.finish_run(run_id, read_count, applied_count, digest.hexdigest(), str(error)[:500])
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
