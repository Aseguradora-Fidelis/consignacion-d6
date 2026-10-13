import { useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { Download, Search } from 'lucide-react';
import { useAuth } from '../auth/AuthProvider';
import { Cargando, Encabezado, ErrorCarga, Estado, Paginacion, Vacio } from '../components/ui';
import { useCartera, useMarcas } from '../data/cartera';
import { supabase } from '../lib/supabase';
import { ESTADO_POLIZA } from '../domain/estados';
import { MOVIMIENTO } from '../domain/glosario';
import { fecha, nombre, q } from '../lib/format';
import { descargarExcel } from '../lib/exportar';
import { useToast } from '../components/ui/Toasts';

const ESTADOS = [
  ['', 'Todos los estados'],
  ['ACTIVAS', 'Activas'],
  ['VIGENTE', 'Vigentes'],
  ['POR_RENOVAR', 'Vencen en 60 días'],
  ['EN_BAJA', 'En proceso de baja'],
  ['VENCIDA', 'Vencidas'],
  ['CANCELADA', 'Canceladas'],
];

export default function Cartera() {
  const { usuario } = useAuth();
  const [params, setParams] = useSearchParams();
  const navegar = useNavigate();
  const toast = useToast();
  const [texto, setTexto] = useState(params.get('buscar') || '');
  const pagina = Number(params.get('pagina') || 1);
  const estado = params.get('estado') ?? 'ACTIVAS';
  const marcaId = params.get('marca') || '';
  const movimiento = params.get('movimiento') || '';
  const marcas = useMarcas();
  const { data, isLoading, isFetching, error, refetch } = useCartera({ pagina, buscar: params.get('buscar') || '', estado, marcaId, movimiento });

  function cambiar(cambios) {
    const nuevo = new URLSearchParams(params);
    Object.entries(cambios).forEach(([k, v]) => (v ? nuevo.set(k, v) : nuevo.delete(k)));
    if (!('pagina' in cambios)) nuevo.delete('pagina');
    if ('estado' in cambios && !cambios.estado) nuevo.set('estado', '');
    setParams(nuevo, { replace: true });
  }

  async function exportar() {
    try {
      let consulta = supabase.from('v_fianzas')
        .select('fianza,endoso,cliente_codigo,cliente_nombre,beneficiario_nombre,marca_nombre,fecha_emision,vigencia_desde,vigencia_hasta,estado,movimiento,fecha_cancelacion,monto_afianzado,prima,derechos,iva,contrato_numero');
      if (estado === 'ACTIVAS') consulta = consulta.in('estado', ['VIGENTE', 'POR_RENOVAR', 'EN_BAJA']);
      else if (estado) consulta = consulta.eq('estado', estado);
      if (marcaId) consulta = consulta.eq('marca_id', marcaId);
      if (movimiento) consulta = consulta.eq('movimiento', movimiento);
      const { data: filas, error: e } = await consulta.order('vigencia_hasta').limit(10000);
      if (e) throw e;
      await descargarExcel(`cartera-d6-${new Date().toISOString().slice(0, 10)}.xlsx`, 'Cartera', filas.map((f) => ({
        Fianza: f.fianza, Endoso: f.endoso, 'Código afianzado': f.cliente_codigo, Afianzado: nombre(f.cliente_nombre),
        Beneficiario: nombre(f.beneficiario_nombre), Marca: f.marca_nombre, Emisión: f.fecha_emision,
        'Vigente desde': f.vigencia_desde, 'Vigente hasta': f.vigencia_hasta, Estado: ESTADO_POLIZA[f.estado]?.texto || f.estado,
        Movimiento: MOVIMIENTO[f.movimiento]?.texto || '', 'Fecha de cancelación': f.fecha_cancelacion,
        'Monto afianzado': Number(f.monto_afianzado), Prima: Number(f.prima), Derechos: Number(f.derechos), IVA: Number(f.iva),
        Contrato: f.contrato_numero,
      })));
    } catch (e) {
      toast.error(e);
    }
  }

  const filas = data?.data || [];

  return (
    <div>
      <Encabezado
        titulo={usuario.esMarca ? 'Mi cartera' : 'Cartera D-6'}
        descripcion="El estado se calcula con las fechas de vigencia. Verde: nueva. Amarillo: se cancela en una fecha futura. Rojo: cancelada hace poco."
        acciones={<button className="btn btn-secundario" onClick={exportar}><Download size={18} aria-hidden="true" /> Descargar Excel</button>}
      />

      <form
        className="filtros"
        role="search"
        onSubmit={(e) => {
          e.preventDefault();
          cambiar({ buscar: texto.trim() });
        }}
      >
        <div className="buscar row" style={{ gap: '0.5rem', flexWrap: 'nowrap' }}>
          <input
            className="control"
            style={{ width: '100%' }}
            placeholder="Número de fianza, código o nombre del afianzado"
            aria-label="Buscar en la cartera"
            value={texto}
            onChange={(e) => setTexto(e.target.value)}
          />
          <button className="btn btn-secundario btn-sm" type="submit" aria-label="Buscar"><Search size={16} /></button>
        </div>
        <select className="control" aria-label="Estado" value={estado} onChange={(e) => cambiar({ estado: e.target.value })}>
          {ESTADOS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
        </select>
        <select className="control" aria-label="Movimiento" value={movimiento} onChange={(e) => cambiar({ movimiento: e.target.value })}>
          <option value="">Cualquier movimiento</option>
          {Object.entries(MOVIMIENTO).map(([v, m]) => <option key={v} value={v}>{m.texto}: {m.ayuda.toLowerCase()}</option>)}
        </select>
        {(marcas.data?.length || 0) > 1 && (
          <select className="control" aria-label="Marca" value={marcaId} onChange={(e) => cambiar({ marca: e.target.value })}>
            <option value="">Todas las marcas</option>
            {marcas.data.map((m) => <option key={m.id} value={m.id}>{m.nombre}</option>)}
          </select>
        )}
        {(params.get('buscar') || marcaId || movimiento || estado !== 'ACTIVAS') && (
          <button type="button" className="btn btn-texto btn-sm" onClick={() => { setTexto(''); setParams({}, { replace: true }); }}>
            Quitar filtros
          </button>
        )}
        {isFetching && !isLoading && <span className="spinner" aria-label="Actualizando" />}
      </form>

      {isLoading && <Cargando />}
      {error && <ErrorCarga error={error} reintentar={refetch} />}
      {!isLoading && !error && filas.length === 0 && (
        <Vacio titulo="No hay fianzas con esos filtros">Pruebe con otro estado o quite la búsqueda.</Vacio>
      )}
      {filas.length > 0 && (
        <>
          <div className="tabla-marco">
            <table className="tabla">
              <thead>
                <tr>
                  <th>Fianza</th>
                  <th>Afianzado</th>
                  {!usuario.esMarca || usuario.marcas.length > 1 ? <th>Beneficiario</th> : null}
                  <th>Vigencia</th>
                  <th>Estado</th>
                  <th className="derecha">Monto afianzado</th>
                </tr>
              </thead>
              <tbody>
                {filas.map((f) => (
                  <tr key={f.id} className={`clic ${f.movimiento ? `fila-${f.movimiento.toLowerCase()}` : ''}`} onClick={() => navegar(`/cartera/${f.id}`)}>
                    <td>
                      <Link to={`/cartera/${f.id}`} className="principal-celda num" onClick={(e) => e.stopPropagation()}>{f.fianza}</Link>
                      {f.endoso > 0 && <span className="secundaria-celda">Endoso {f.endoso}</span>}
                    </td>
                    <td>
                      {nombre(f.cliente_nombre)}
                      <span className="secundaria-celda">Código {f.cliente_codigo}</span>
                    </td>
                    {!usuario.esMarca || usuario.marcas.length > 1 ? (
                      <td className="small">{nombre(f.beneficiario_nombre)}</td>
                    ) : null}
                    <td className="num small">{fecha(f.vigencia_desde)} al {fecha(f.vigencia_hasta)}</td>
                    <td>
                      <Estado mapa={ESTADO_POLIZA} valor={f.estado} />
                      {f.movimiento === 'CANCELA' && f.fecha_cancelacion && <span className="secundaria-celda">Cancela el {fecha(f.fecha_cancelacion)}</span>}
                      {f.movimiento === 'NUEVA' && <span className="chip-mov nueva">Nueva</span>}
                    </td>
                    <td className="derecha num">
                      {q(f.monto_original)}
                      {Number(f.monto_afianzado) === 0 && Number(f.monto_original) > 0 && <span className="secundaria-celda">Monto antes de cancelar</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <Paginacion pagina={pagina} porPagina={25} total={data?.count || 0} onCambiar={(p) => cambiar({ pagina: String(p) })} />
        </>
      )}
    </div>
  );
}
