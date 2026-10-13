"""Copia las facturas D-6 de FISO a Supabase. El estado de cuenta de cada marca se arma con ellas.

Lee main_fusa.FAC_FACTURA (solo lectura, transaccion READ ONLY) para las fianzas de clase D-6,
escribe en oracle_d6_staging (fuente FACTURAS_D6) y llama d6_aplicar_facturas_fiso.

  python integrations/oracle/cargar_facturas.py              # este año y el anterior
  python integrations/oracle/cargar_facturas.py --desde 2026-01-01

Necesita ORACLE_HOST, ORACLE_SID, ORACLE_USER, ORACLE_PASSWORD, SUPABASE_URL y
SUPABASE_SERVICE_ROLE_KEY. No imprime datos de clientes.

Por que facturas y no polizas (cruce del 2026-10-08): FISO factura D-6 en cuotas mensuales a
todas las marcas menos UMA, no factura los endosos de aplicacion de primas, cancelacion ni
habilitacion, y un endoso a 60 meses se factura como una prima anual.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import sys

from refresh_d6 import Supabase, conectar_oracle, json_default, only_read

# Beneficiario del ultimo endoso de cada fianza D-6: una fianza puede cambiar de beneficiario.
SQL_FACTURAS_D6 = only_read("""
WITH d6 AS (
  SELECT ramo, fianza, cod_contacto_beneficiario
  FROM (SELECT p.ramo, p.fianza, p.cod_contacto_beneficiario,
               ROW_NUMBER() OVER (PARTITION BY p.ramo, p.fianza ORDER BY p.endoso DESC) rn
        FROM main_fusa.FIA_POLIZA p
        WHERE p.clase = 'D-6')
  WHERE rn = 1
)
SELECT f.serie AS SERIE, f.factura AS FACTURA, f.ramo AS RAMO, f.fianza AS FIANZA, f.endoso AS ENDOSO,
       d6.cod_contacto_beneficiario AS COD_CONTACTO_BENEFICIARIO,
       f.fec_emision AS FEC_EMISION, f.prima AS PRIMA, f.derechos AS DERECHOS, f.otros AS OTROS, f.iva AS IVA,
       f.total_factura AS TOTAL_FACTURA, f.saldo_factura AS SALDO_FACTURA, f.fec_pago AS FEC_PAGO,
       f.fec_anulacion AS FEC_ANULACION, f.meses_plazo AS MESES_PLAZO,
       f.correlativo_unico_cobro AS CORRELATIVO_UNICO_COBRO, f.cod_estado_documento AS COD_ESTADO_DOCUMENTO
FROM main_fusa.FAC_FACTURA f
JOIN d6 ON d6.ramo = f.ramo AND d6.fianza = f.fianza
WHERE f.fec_emision >= :desde
""")


def texto(valor):
    if isinstance(valor, (dt.date, dt.datetime)):
        return valor.strftime("%Y-%m-%d")
    return valor


def leer_oracle(desde: dt.date):
    with conectar_oracle() as conexion:
        cursor = conexion.cursor()
        cursor.execute(SQL_FACTURAS_D6, {"desde": desde})
        nombres = [c[0].upper() for c in cursor.description]
        for fila in cursor:
            yield {k: texto(v) for k, v in zip(nombres, fila)}


def main():
    hoy = dt.date.today()
    parser = argparse.ArgumentParser()
    parser.add_argument("--desde", type=dt.date.fromisoformat, default=dt.date(hoy.year - 1, 1, 1))
    args = parser.parse_args()

    supabase = Supabase()
    corrida = supabase.request("POST", "oracle_sync_runs_d6", {
        "fuente": "FACTURAS_D6", "estado": "INICIADO", "ventana_desde": args.desde.isoformat(),
    }, "return=representation")[0]["id"]
    leidas = 0
    huella = hashlib.sha256()
    lote = []
    try:
        for fila in leer_oracle(args.desde):
            huella.update(json.dumps(fila, default=json_default, sort_keys=True, separators=(",", ":")).encode())
            lote.append({
                "sync_run_id": corrida, "fuente": "FACTURAS_D6", "source_key": str(fila["CORRELATIVO_UNICO_COBRO"]),
                "periodo": fila["FEC_EMISION"], "payload": fila,
            })
            leidas += 1
            if len(lote) == 500:
                supabase.upsert_staging(lote)
                lote.clear()
        supabase.upsert_staging(lote)
        resumen = supabase.request("POST", "rpc/d6_aplicar_facturas_fiso", {"p_run_id": corrida})
        supabase.finish_run(corrida, leidas, resumen["facturas_nuevas"], huella.hexdigest())
        print(
            f"Facturas D-6 desde {args.desde}: leidas={leidas} nuevas={resumen['facturas_nuevas']} "
            f"pagos_confirmados={resumen['pagos_confirmados']} sin_beneficiario={resumen['sin_beneficiario']} "
            f"sin_marca={resumen['sin_marca']}"
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
