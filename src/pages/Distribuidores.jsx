import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { Plus, Search } from 'lucide-react';
import { useAuth } from '../auth/AuthProvider';
import { Cargando, Encabezado, ErrorCarga, Estado, Paginacion, Vacio } from '../components/ui';
import { useMarcas } from '../data/cartera';
import { useDistribuidores } from '../data/operacion';
import { diasHasta, fecha, nombre, numero, q } from '../lib/format';

const ORDENES = [
  ['monto_activo', 'Mayor monto activo'],
  ['proximo_vencimiento', 'Vence primero'],
  ['ultima_emision', 'Emisión más reciente'],
];

export default function Distribuidores() {
  const { usuario, puede } = useAuth();
  const [params, setParams] = useSearchParams();
  const [texto, setTexto] = useState(params.get('buscar') || '');
  const pagina = Number(params.get('pagina') || 1);
  const orden = params.get('orden') || 'monto_activo';
  const marcaId = params.get('marca') || '';
  const soloActivos = params.get('todos') !== '1';
  const marcas = useMarcas();
  const { data, isLoading, error, refetch } = useDistribuidores({ pagina, buscar: params.get('buscar') || '', orden, marcaId, soloActivos });

  function cambiar(cambios) {
    const nuevo = new URLSearchParams(params);
    Object.entries(cambios).forEach(([k, v]) => (v ? nuevo.set(k, v) : nuevo.delete(k)));
    if (!('pagina' in cambios)) nuevo.delete('pagina');
    setParams(nuevo, { replace: true });
  }

  const filas = data?.data || [];

  return (
    <div>
      <Encabezado
        titulo={usuario.esMarca ? 'Mis distribuidores' : 'Distribuidores'}
        descripcion="Cada distribuidor con sus fianzas activas, el monto que tiene cubierto y cuándo vence."
        acciones={puede('solicitarAlta') && (
          <Link className="btn btn-primario" to="/altas/nueva"><Plus size={18} aria-hidden="true" /> Nuevo distribuidor o incremento</Link>
        )}
      />

      <form className="filtros" role="search" onSubmit={(e) => { e.preventDefault(); cambiar({ buscar: texto.trim() }); }}>
        <div className="buscar row" style={{ gap: '0.5rem', flexWrap: 'nowrap' }}>
          <input className="control" style={{ width: '100%' }} placeholder="Nombre o código del distribuidor" aria-label="Buscar distribuidor"
            value={texto} onChange={(e) => setTexto(e.target.value)} />
          <button className="btn btn-secundario btn-sm" type="submit" aria-label="Buscar"><Search size={16} /></button>
        </div>
        <select className="control" aria-label="Orden" value={orden} onChange={(e) => cambiar({ orden: e.target.value })}>
          {ORDENES.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
        </select>
        {(marcas.data?.length || 0) > 1 && (
          <select className="control" aria-label="Marca" value={marcaId} onChange={(e) => cambiar({ marca: e.target.value })}>
            <option value="">Todas las marcas</option>
            {marcas.data.map((m) => <option key={m.id} value={m.id}>{m.nombre}</option>)}
          </select>
        )}
        <label className="row small" style={{ gap: '0.4rem' }}>
          <input type="checkbox" checked={!soloActivos} onChange={(e) => cambiar({ todos: e.target.checked ? '1' : '' })} />
          Incluir sin fianza activa
        </label>
      </form>

      {isLoading && <Cargando />}
      {error && <ErrorCarga error={error} reintentar={refetch} />}
      {!isLoading && !error && !filas.length && <Vacio titulo="No hay distribuidores con esos filtros" />}
      {filas.length > 0 && (
        <>
          <div className="tabla-marco">
            <table className="tabla">
              <thead>
                <tr>
                  <th>Distribuidor</th>
                  {(!usuario.esMarca || usuario.marcas.length > 1) && <th>Marca</th>}
                  <th className="derecha">Fianzas activas</th>
                  <th className="derecha">Monto cubierto</th>
                  <th>Próximo vencimiento</th>
                  <th>Cliente desde</th>
                </tr>
              </thead>
              <tbody>
                {filas.map((d) => {
                  const dias = diasHasta(d.proximo_vencimiento);
                  return (
                    <tr key={`${d.cliente_id}-${d.marca_id}`}>
                      <td>
                        <Link className="principal-celda" to={`/cartera?buscar=${d.cliente_codigo}&estado=`}>{nombre(d.cliente_nombre)}</Link>
                        <span className="secundaria-celda">Código {d.cliente_codigo}</span>
                      </td>
                      {(!usuario.esMarca || usuario.marcas.length > 1) && <td className="small">{d.marca_nombre}</td>}
                      <td className="derecha num">{numero(d.fianzas_activas)}</td>
                      <td className="derecha num">{q(d.monto_activo)}</td>
                      <td>
                        {d.proximo_vencimiento ? <span className="num small">{fecha(d.proximo_vencimiento)}</span> : <span className="muted small">Sin fianza activa</span>}
                        {dias !== null && dias <= 60 && dias >= 0 && <span className="secundaria-celda"><Estado texto={`Vence en ${dias} días`} tono="atencion" /></span>}
                        {Number(d.en_baja) > 0 && <span className="secundaria-celda"><Estado texto="Con baja programada" tono="atencion" /></span>}
                      </td>
                      <td className="small num">{fecha(d.cliente_desde)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <Paginacion pagina={pagina} porPagina={30} total={data?.count || 0} onCambiar={(p) => cambiar({ pagina: String(p) })} />
        </>
      )}
    </div>
  );
}
