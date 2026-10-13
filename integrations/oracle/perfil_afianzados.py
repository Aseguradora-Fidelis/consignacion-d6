"""Perfil de riesgo de cada afianzado D-6 desde Oracle hacia Supabase (perfil_afianzado_oracle).

Por cada cliente con al menos una fianza D-6 trae, ya agregado por cliente:
  * IVE: ultima fecha de renovacion y si esta completo y verificado (MG_CONTACTOS_IVE).
  * Contragarantias vigentes: monto y tipos (CONTRAGARANTIA_CONTRAGARANTIAS).
  * Cumulo autorizado (CUMULO_MULTIPLE_CONTACTO).
  * Cuenta por cobrar viva: saldo, saldo atrasado y dias de atraso (VW_SALDO_FACTURA).
  * Reclamos y avisos en la bitacora (RECLAMO_BITACORAS).
  * Otras fianzas vigentes del cliente fuera de D-6 (FIA_POLIZA).
  * Senas para detectar vinculados: direccion, municipio, telefonos, patente y apellidos
    (MG_CONTACTOS y MG_DIRECCIONES).
Cada fuente se agrega por cliente ANTES de unirse: un join directo multiplica montos
(AI MEMORY/db/cola-operativa.md, trampa del 443x). Solo lectura. No imprime datos personales.

Uso: python integrations/oracle/perfil_afianzados.py
Necesita ORACLE_* y SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.
"""
from __future__ import annotations

import datetime as dt
import re
import sys

from refresh_d6 import Supabase, conectar_oracle, only_read

SQL_PERFIL = only_read("""
WITH d6 AS (
  SELECT DISTINCT TRIM(TO_CHAR(cod_contacto_cliente)) cli FROM main_fusa.FIA_POLIZA WHERE clase = 'D-6'
),
ive AS (
  SELECT TRIM(TO_CHAR(cod_contacto)) cli, MAX(fecha_renovacion) fecha_renovacion,
         MAX(CASE WHEN completo_sn = 'S' THEN 1 ELSE 0 END) completo,
         MAX(CASE WHEN verificado_sn = 'S' THEN 1 ELSE 0 END) verificado
  FROM main_fusa.MG_CONTACTOS_IVE GROUP BY TRIM(TO_CHAR(cod_contacto))
),
cg AS (
  SELECT TRIM(TO_CHAR(cod_contacto_cliente)) cli, SUM(monto_total_quetzales) monto, COUNT(*) instrumentos
  FROM main_fusa.CONTRAGARANTIA_CONTRAGARANTIAS WHERE UPPER(estado) = 'VIGENTE'
  GROUP BY TRIM(TO_CHAR(cod_contacto_cliente))
),
cg_tipos AS (
  SELECT cli, LISTAGG(tipo, ', ') WITHIN GROUP (ORDER BY tipo) tipos FROM (
    SELECT DISTINCT TRIM(TO_CHAR(cod_contacto_cliente)) cli, tipo
    FROM main_fusa.CONTRAGARANTIA_CONTRAGARANTIAS WHERE UPPER(estado) = 'VIGENTE'
  ) GROUP BY cli
),
cu AS (
  SELECT TRIM(TO_CHAR(cod_contacto)) cli, MAX(valor_multiple) valor FROM main_fusa.CUMULO_MULTIPLE_CONTACTO GROUP BY TRIM(TO_CHAR(cod_contacto))
),
sal AS (
  SELECT TRIM(TO_CHAR(cod_contacto_cliente)) cli, SUM(saldo_total) saldo,
         SUM(CASE WHEN dias_atraso > 0 THEN saldo_total ELSE 0 END) atrasado,
         SUM(CASE WHEN dias_atraso > 90 THEN saldo_total ELSE 0 END) atrasado_90,
         MAX(dias_atraso) max_dias
  FROM main_fusa.VW_SALDO_FACTURA GROUP BY TRIM(TO_CHAR(cod_contacto_cliente))
),
rec AS (
  SELECT TRIM(TO_CHAR(cod_contacto_cliente)) cli,
         SUM(CASE WHEN estado = 'Reclamo' THEN 1 ELSE 0 END) reclamos,
         SUM(CASE WHEN estado = 'Aviso' THEN 1 ELSE 0 END) avisos,
         MAX(created_at) ultimo
  FROM main_fusa.RECLAMO_BITACORAS WHERE estado IN ('Reclamo', 'Aviso')
  GROUP BY TRIM(TO_CHAR(cod_contacto_cliente))
),
otras AS (
  SELECT cli, COUNT(*) vigentes, SUM(monto_afianzado) monto FROM (
    SELECT TRIM(TO_CHAR(p.cod_contacto_cliente)) cli, p.monto_afianzado,
           ROW_NUMBER() OVER (PARTITION BY p.fianza ORDER BY p.endoso DESC) rn, p.status, p.vigencia_hasta, p.clase
    FROM main_fusa.FIA_POLIZA p
    WHERE p.clase <> 'D-6' AND TRIM(TO_CHAR(p.cod_contacto_cliente)) IN (SELECT cli FROM d6)
  ) WHERE rn = 1 AND status = 'V' AND vigencia_hasta >= TRUNC(SYSDATE)
  GROUP BY cli
),
con AS (
  SELECT TRIM(TO_CHAR(c.cod_contacto)) cli,
         TRIM(c.apellido1 || ' ' || c.apellido2) apellidos,
         TRIM(c.patente_empresa_numero || '-' || c.patente_empresa_folio || '-' || c.patente_empresa_libro) patente,
         c.numero_celular celular, c.telefono_fijo fijo
  FROM main_fusa.MG_CONTACTOS c WHERE TRIM(TO_CHAR(c.cod_contacto)) IN (SELECT cli FROM d6)
),
dir AS (
  SELECT cli, direccion, municipio FROM (
    SELECT TRIM(TO_CHAR(d.cod_contacto)) cli, d.direccion_string direccion,
           TO_CHAR(d.cod_departamento) || '-' || TO_CHAR(d.cod_municipio) municipio,
           ROW_NUMBER() OVER (PARTITION BY d.cod_contacto ORDER BY d.cod_direccion) rn
    FROM main_fusa.MG_DIRECCIONES d WHERE TRIM(TO_CHAR(d.cod_contacto)) IN (SELECT cli FROM d6)
  ) WHERE rn = 1
),
tel AS (
  SELECT TRIM(TO_CHAR(d.cod_contacto)) cli,
         LISTAGG(d.telefono1 || ',' || d.telefono2, ',') WITHIN GROUP (ORDER BY d.cod_direccion) telefonos
  FROM main_fusa.MG_DIRECCIONES d WHERE TRIM(TO_CHAR(d.cod_contacto)) IN (SELECT cli FROM d6)
  GROUP BY TRIM(TO_CHAR(d.cod_contacto))
)
SELECT d6.cli AS CLIENTE_CODIGO,
       ive.fecha_renovacion AS IVE_FECHA_RENOVACION, ive.completo AS IVE_COMPLETO, ive.verificado AS IVE_VERIFICADO,
       cg.monto AS CONTRAGARANTIA_MONTO, cg_tipos.tipos AS CONTRAGARANTIA_TIPOS, cg.instrumentos AS CONTRAGARANTIA_INSTRUMENTOS,
       cu.valor AS CUMULO,
       sal.saldo AS SALDO, sal.atrasado AS SALDO_ATRASADO, sal.atrasado_90 AS SALDO_ATRASADO_90, sal.max_dias AS MAX_DIAS_ATRASO,
       rec.reclamos AS RECLAMOS, rec.avisos AS AVISOS, rec.ultimo AS ULTIMO_RECLAMO,
       otras.vigentes AS OTRAS_FIANZAS_VIGENTES, otras.monto AS OTRAS_FIANZAS_MONTO,
       con.apellidos AS APELLIDOS, con.patente AS PATENTE, con.celular AS CELULAR, con.fijo AS FIJO,
       dir.direccion AS DIRECCION, dir.municipio AS MUNICIPIO, tel.telefonos AS TELEFONOS
FROM d6
LEFT JOIN ive ON ive.cli = d6.cli
LEFT JOIN cg ON cg.cli = d6.cli
LEFT JOIN cg_tipos ON cg_tipos.cli = d6.cli
LEFT JOIN cu ON cu.cli = d6.cli
LEFT JOIN sal ON sal.cli = d6.cli
LEFT JOIN rec ON rec.cli = d6.cli
LEFT JOIN otras ON otras.cli = d6.cli
LEFT JOIN con ON con.cli = d6.cli
LEFT JOIN dir ON dir.cli = d6.cli
LEFT JOIN tel ON tel.cli = d6.cli
""")


def fecha(v):
    if isinstance(v, (dt.date, dt.datetime)):
        return v.date().isoformat() if isinstance(v, dt.datetime) else v.isoformat()
    return None


def num(v):
    return float(v) if v is not None else 0.0


def telefonos(*valores):
    salida = []
    for v in valores:
        for t in re.split(r"[,;/]", str(v or "")):
            d = re.sub(r"\D", "", t)
            if len(d) >= 8 and d[-8:] not in salida:
                salida.append(d[-8:])
    return salida


def texto(v):
    v = re.sub(r"\s+", " ", str(v or "")).strip(" -")
    return v or None


def leer():
    with conectar_oracle() as conexion:
        cursor = conexion.cursor()
        cursor.execute(SQL_PERFIL)
        nombres = [c[0] for c in cursor.description]
        for fila in cursor:
            yield dict(zip(nombres, fila))


def main():
    supabase = Supabase()
    ahora = dt.datetime.now(dt.timezone.utc).isoformat()
    lote, total = [], 0
    for f in leer():
        if not str(f["CLIENTE_CODIGO"]).isdigit():
            continue
        lote.append({
            "cliente_codigo": int(f["CLIENTE_CODIGO"]),
            "ive_fecha_renovacion": fecha(f["IVE_FECHA_RENOVACION"]),
            "ive_completo": bool(f["IVE_COMPLETO"]),
            "ive_verificado": bool(f["IVE_VERIFICADO"]),
            "contragarantia_monto": num(f["CONTRAGARANTIA_MONTO"]),
            "contragarantia_tipos": f["CONTRAGARANTIA_TIPOS"],
            "contragarantia_instrumentos": int(f["CONTRAGARANTIA_INSTRUMENTOS"] or 0),
            "cumulo": num(f["CUMULO"]) or None,
            "saldo": num(f["SALDO"]),
            "saldo_atrasado": num(f["SALDO_ATRASADO"]),
            "saldo_atrasado_90": num(f["SALDO_ATRASADO_90"]),
            "max_dias_atraso": int(f["MAX_DIAS_ATRASO"] or 0),
            "reclamos": int(f["RECLAMOS"] or 0),
            "avisos": int(f["AVISOS"] or 0),
            "ultimo_reclamo": fecha(f["ULTIMO_RECLAMO"]),
            "otras_fianzas_vigentes": int(f["OTRAS_FIANZAS_VIGENTES"] or 0),
            "otras_fianzas_monto": num(f["OTRAS_FIANZAS_MONTO"]),
            "direccion": texto(f["DIRECCION"]),
            "municipio": texto(f["MUNICIPIO"]),
            "telefonos": telefonos(f["CELULAR"], f["FIJO"], f["TELEFONOS"]),
            "patente": texto(f["PATENTE"]) if texto(f["PATENTE"]) and len(re.sub(r"\W", "", f["PATENTE"] or "")) > 3 else None,
            "apellidos": texto(f["APELLIDOS"]),
            "actualizado_at": ahora,
        })
        if len(lote) == 250:
            supabase.request("POST", "perfil_afianzado_oracle?on_conflict=cliente_codigo", lote, "resolution=merge-duplicates,return=minimal")
            total += len(lote)
            lote.clear()
    if lote:
        supabase.request("POST", "perfil_afianzado_oracle?on_conflict=cliente_codigo", lote, "resolution=merge-duplicates,return=minimal")
        total += len(lote)
    print(f"Perfil D-6: {total} afianzados actualizados")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
