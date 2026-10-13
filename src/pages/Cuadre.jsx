import { useMemo } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { Download } from 'lucide-react';
import { Aviso, Cargando, Encabezado, ErrorCarga, Pestanas, Vacio } from '../components/ui';
import { useToast } from '../components/ui/Toasts';
import { useCuadreFiso, useUltimaCargaOracle } from '../data/operacion';
import { descargarExcel } from '../lib/exportar';
import { fechaHora, nombre, numero } from '../lib/format';

// Solo de consulta (migracion 044): lo que no cuadra entre la app y FISO se corrige en FISO.
const TIPOS = {
  BAJA_PENDIENTE_EN_FISO: {
    texto: 'Bajas pendientes en FISO',
    explica: 'La marca pidió la baja y su fecha ya pasó, pero en FISO la fianza sigue vigente. Mientras FISO no la cancele se le sigue cobrando a la marca.',
    correccion: 'Se cancela en FISO con el número de fianza.',
  },
  RECIBIDA_SIN_EMISION: {
    texto: 'Recibidas sin emisión',
    explica: 'El distribuidor envió su solicitud hace más de 30 días y en FISO no hay una fianza de esa marca con su NIT.',
    correccion: 'Si ya se emitió, revisar que el NIT del contacto en FISO sea el mismo que escribió el distribuidor.',
  },
  CODIGO_DUPLICADO: {
    texto: 'Códigos duplicados',
    explica: 'El mismo nombre aparece con dos códigos de contacto, y los dos tienen fianzas. Pasa cuando se cambia el código o se crea el contacto dos veces.',
    correccion: 'Se unifica el contacto en FISO para que la exposición sume bien.',
  },
  FACTURA_SIN_MARCA: {
    texto: 'Facturas sin marca',
    explica: 'FISO facturó una fianza D-6 a un beneficiario que no está asignado a ninguna marca. Esa factura no aparece en la cuenta de ninguna marca.',
    correccion: 'Administración asigna el beneficiario a su marca.',
  },
};

export default function Cuadre() {
  const toast = useToast();
  const [params, setParams] = useSearchParams();
  const { data, isLoading, error, refetch } = useCuadreFiso();
  const carga = useUltimaCargaOracle();
  const conteo = useMemo(() => {
    const r = {};
    for (const c of data || []) r[c.tipo] = (r[c.tipo] || 0) + 1;
    return r;
  }, [data]);
  const primero = Object.keys(TIPOS).find((k) => conteo[k]) || 'BAJA_PENDIENTE_EN_FISO';
  const tipo = params.get('tipo') || primero;
  const filas = (data || []).filter((c) => c.tipo === tipo);
  const info = TIPOS[tipo] || TIPOS.BAJA_PENDIENTE_EN_FISO;

  async function exportar() {
    try {
      await descargarExcel(`cuadre-fiso-${new Date().toISOString().slice(0, 10)}.xlsx`, 'Cuadre', (data || []).map((c) => ({
        Tipo: TIPOS[c.tipo]?.texto || c.tipo, Fianza: c.fianza, Afianzado: nombre(c.afianzado), Marca: c.marca, Detalle: c.detalle,
      })));
    } catch (e) {
      toast.error(e);
    }
  }

  return (
    <div>
      <Encabezado
        titulo="Cuadre con FISO"
        descripcion={carga.data
          ? `Compara la app con la carga de FISO del ${fechaHora(carga.data.ejecutado_en)}. Solo de consulta.`
          : 'Compara la app con la última carga de FISO. Solo de consulta.'}
        acciones={data?.length > 0 && <button className="btn btn-secundario" onClick={exportar}><Download size={18} aria-hidden="true" /> Descargar todo</button>}
      />
      {isLoading && <Cargando />}
      {error && <ErrorCarga error={error} reintentar={refetch} />}
      {data && data.length === 0 && <Vacio titulo="La app cuadra con FISO">No hay diferencias en la última carga.</Vacio>}
      {data?.length > 0 && (
        <>
          <Pestanas
            valor={tipo}
            onCambiar={(v) => setParams({ tipo: v }, { replace: true })}
            opciones={Object.entries(TIPOS).map(([k, t]) => ({ valor: k, texto: t.texto, contador: numero(conteo[k] || 0) }))}
          />
          <Aviso titulo={info.explica}>{info.correccion}</Aviso>
          {filas.length === 0 ? (
            <Vacio titulo="Sin diferencias de este tipo" />
          ) : (
            <div className="tabla-marco" style={{ marginTop: '1rem' }}>
              <table className="tabla">
                <thead><tr><th>Fianza</th><th>Afianzado</th><th>Marca</th><th>Detalle</th></tr></thead>
                <tbody>
                  {filas.map((c, i) => (
                    <tr key={`${c.fianza_id || c.cliente_id}-${i}`}>
                      <td>{c.fianza_id ? <Link className="principal-celda num" to={`/cartera/${c.fianza_id}`}>{c.fianza}</Link> : <span className="muted">Sin fianza</span>}</td>
                      <td>{c.cliente_id ? <Link to={`/afianzados/${c.cliente_id}`}>{nombre(c.afianzado)}</Link> : nombre(c.afianzado)}</td>
                      <td className="small">{c.marca}</td>
                      <td className="small">{c.detalle}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </div>
  );
}
