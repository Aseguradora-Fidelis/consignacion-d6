"""Carga la cartera D-6 en Supabase y la aplica al modelo de la app.

Dos origenes, mismo resultado:
  --csv RUTA     El export d6-consignacion.csv (UTF-8, campos con saltos de linea).
  --oracle       Lee de Oracle con SQL_CARTERA_D6 (solo lectura). La consulta debe
                 validarse contra el export antes de usarse en produccion.

Escribe en oracle_d6_staging (fuente CARTERA_D6) y llama d6_aplicar_cartera_oracle.
Necesita SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY. No imprime datos de clientes.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import sys

from refresh_d6 import Supabase, conectar_oracle, json_default, only_read

COLUMNAS = [
    "RAMO", "FIANZA", "ENDOSO", "CLASE", "COD_CONTACTO_CLIENTE", "NOMBRE_CLIENTE", "COD_CONTACTO_BENEFICIARIO",
    "NOMBRE_BENEFICIARIO", "NUMERO_AGENTE", "INDICE_AGENTE", "NOMBRE_AGENTE", "FECHA_EMISION", "VIGENCIA_DESDE",
    "VIGENCIA_HASTA", "FECHA_CANCELACION", "FECHA_ANULACION", "COD_ESTADO_POLIZA", "STATUS", "MONTO_AFIANZADO",
    "PRIMA", "DERECHOS", "OTROS", "GASTOS_ENVIO", "IVA", "PRIMA_ANUAL", "CONTRATO_NUMERO", "CONTRATO_FECHA",
    "CONTRATO_VALOR", "TEMA_DE_FIANZA",
]
# El NIT del distribuidor solo viene de Oracle (contactos de FISO). Con el la app reconoce sola
# la fianza emitida para cada solicitud. El export CSV no lo trae.
OPCIONALES = ["NIT_CLIENTE"]
FECHAS = {"FECHA_EMISION", "VIGENCIA_DESDE", "VIGENCIA_HASTA", "FECHA_CANCELACION", "FECHA_ANULACION", "CONTRATO_FECHA"}

# Ultimo endoso de cada fianza D-6 con los nombres que usa el export. Validada contra
# d6-consignacion.csv el 2026-10-06 con scratch/validar_cartera.py (ver README).
SQL_CARTERA_D6 = """
WITH ult AS (
  SELECT p.*, ROW_NUMBER() OVER (PARTITION BY p.fianza ORDER BY p.endoso DESC) rn
  FROM main_fusa.FIA_POLIZA p
  WHERE p.clase = 'D-6'
)
SELECT u.ramo AS RAMO, u.fianza AS FIANZA, u.endoso AS ENDOSO, u.clase AS CLASE,
       u.cod_contacto_cliente AS COD_CONTACTO_CLIENTE,
       main_fusa.PKG_GENERAL.NOMBRE_CONTACTO(u.cod_contacto_cliente) AS NOMBRE_CLIENTE,
       u.cod_contacto_beneficiario AS COD_CONTACTO_BENEFICIARIO,
       main_fusa.PKG_GENERAL.NOMBRE_CONTACTO(u.cod_contacto_beneficiario) AS NOMBRE_BENEFICIARIO,
       u.numero_agente AS NUMERO_AGENTE, u.indice AS INDICE_AGENTE,
       CASE WHEN NVL(u.numero_agente, 0) = 0 THEN 'AGENTE DIRECTO'
            ELSE (SELECT MAX(a.nombre) FROM main_fusa.OLD_AGENTES a WHERE a.agente = u.numero_agente AND a.indice = u.indice) END AS NOMBRE_AGENTE,
       u.fecha_emision AS FECHA_EMISION, u.vigencia_desde AS VIGENCIA_DESDE, u.vigencia_hasta AS VIGENCIA_HASTA,
       u.fecha_cancelacion AS FECHA_CANCELACION, u.fecha_anulacion AS FECHA_ANULACION,
       u.cod_estado_poliza AS COD_ESTADO_POLIZA, u.status AS STATUS,
       u.monto_afianzado AS MONTO_AFIANZADO, u.prima AS PRIMA, u.derechos AS DERECHOS, u.otros AS OTROS,
       u.gastos_envio AS GASTOS_ENVIO, u.iva AS IVA, u.prima_anual AS PRIMA_ANUAL,
       u.contrato_numero AS CONTRATO_NUMERO, u.contrato_fecha AS CONTRATO_FECHA, u.contrato_valor AS CONTRATO_VALOR,
       u.tema_de_fianza AS TEMA_DE_FIANZA,
       (SELECT MAX(v.nit) FROM main_fusa.VW_FUSA_CONTACTOS v WHERE v.cod_contacto = u.cod_contacto_cliente) AS NIT_CLIENTE
FROM ult u
WHERE u.rn = 1
"""


def fecha_iso(valor: str) -> str | None:
    """dd/mm/yy o dd/mm/yyyy a ISO. Anos de dos digitos menores a 70 son 20xx."""
    valor = (valor or "").strip()
    if not valor:
        return None
    if isinstance(valor, (dt.date, dt.datetime)):
        return valor.strftime("%Y-%m-%d")
    dia, mes, anio = valor.split(" ")[0].split("/")
    anio = int(anio)
    if anio < 100:
        anio += 2000 if anio < 70 else 1900
    return dt.date(anio, int(mes), int(dia)).isoformat()


def leer_csv(ruta: str):
    with open(ruta, encoding="utf-8", newline="") as archivo:
        for fila in csv.DictReader(archivo):
            faltan = [c for c in COLUMNAS if c not in fila]
            if faltan:
                raise RuntimeError(f"El CSV no tiene las columnas: {', '.join(faltan)}")
            yield {c: (fecha_iso(fila[c]) if c in FECHAS else (fila[c] or "").strip()) for c in COLUMNAS}


def leer_oracle():
    with conectar_oracle() as conexion:
        cursor = conexion.cursor()
        cursor.execute(only_read(SQL_CARTERA_D6))
        nombres = [c[0].upper() for c in cursor.description]
        for fila in cursor:
            datos = dict(zip(nombres, fila))
            yield {c: (datos[c].strftime("%Y-%m-%d") if isinstance(datos.get(c), (dt.date, dt.datetime)) else datos.get(c))
                   for c in COLUMNAS + OPCIONALES if c in datos}


def main():
    parser = argparse.ArgumentParser()
    origen = parser.add_mutually_exclusive_group(required=True)
    origen.add_argument("--csv")
    origen.add_argument("--oracle", action="store_true")
    args = parser.parse_args()

    supabase = Supabase()
    corrida = supabase.request("POST", "oracle_sync_runs_d6", {"fuente": "CARTERA_D6", "estado": "INICIADO"}, "return=representation")[0]["id"]
    leidas = 0
    huella = hashlib.sha256()
    lote = []
    try:
        filas = leer_csv(args.csv) if args.csv else leer_oracle()
        for fila in filas:
            texto = json.dumps(fila, default=json_default, sort_keys=True, separators=(",", ":"))
            huella.update(texto.encode())
            lote.append({
                "sync_run_id": corrida, "fuente": "CARTERA_D6", "source_key": f"{fila['FIANZA']}-{fila['ENDOSO'] or 0}",
                "periodo": fila["FECHA_EMISION"], "payload": fila,
            })
            leidas += 1
            if len(lote) == 250:
                supabase.upsert_staging(lote)
                lote.clear()
        supabase.upsert_staging(lote)
        # Cartera, NIT de los distribuidores y emisiones reconocidas, en un solo paso.
        resumen = supabase.request("POST", "rpc/d6_aplicar_cartera_fiso", {"p_run_id": corrida})
        supabase.finish_run(corrida, leidas, resumen["polizas_nuevas"] + resumen["polizas_actualizadas"], huella.hexdigest())
        print(
            f"Cartera D-6: filas={resumen['filas']} nuevas={resumen['polizas_nuevas']} "
            f"actualizadas={resumen['polizas_actualizadas']} endosos_reemplazados={resumen['endosos_reemplazados']} "
            f"clientes_nuevos={resumen['clientes_nuevos']} beneficiarios_sin_marca={len(resumen['beneficiarios_sin_marca'])} "
            f"emitidas_en_app_sin_oracle={len(resumen['emitidas_en_app_sin_oracle'])} "
            f"nits={resumen.get('nits_actualizados', 0)} solicitudes_emitidas={resumen.get('solicitudes_emitidas', 0)}"
        )
    except Exception as error:
        supabase.finish_run(corrida, leidas, 0, huella.hexdigest(), str(error)[:500])
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
