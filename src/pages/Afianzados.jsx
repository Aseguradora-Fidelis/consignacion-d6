import { useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { Fingerprint, Gavel, ShieldAlert, ShieldOff, TrendingUp, Users } from 'lucide-react';
import { Cargando, Encabezado, ErrorCarga, Estado, Kpi, Paginacion, Vacio } from '../components/ui';
import { useAfianzados, useResumenRiesgo } from '../data/perfil';
import { NIVEL_RIESGO } from '../domain/estados';
import { fecha, fechaHora, nombre, numero, q, qCorto } from '../lib/format';

const ALERTAS = [
  ['', 'Todas las alertas'],
  ['alerta_reclamo', 'Con reclamo'],
  ['alerta_atraso_90', 'Mora de más de 90 días'],
  ['alerta_atraso', 'Mora de más de 60 días'],
  ['alerta_accesorio', 'Sobre Q300,000 sin contragarantía'],
  ['alerta_ive', 'IVE vencido'],
];

export function ChipsAlerta({ a }) {
  return (
    <div className="row" style={{ gap: '0.3rem' }}>
      {a.alerta_reclamo && <Estado texto="Reclamo" tono="critico" />}
      {a.alerta_atraso_90 && <Estado texto={`Mora ${a.max_dias_atraso} d`} tono="critico" />}
      {!a.alerta_atraso_90 && a.alerta_atraso && <Estado texto={`Mora ${a.max_dias_atraso} d`} tono="atencion" />}
      {a.alerta_accesorio && <Estado texto="Sin contragarantía" tono="atencion" />}
      {a.alerta_ive && <Estado texto="IVE vencido" tono="atencion" />}
    </div>
  );
}

export default function Afianzados() {
  const [params, setParams] = useSearchParams();
  const navegar = useNavigate();
  const [texto, setTexto] = useState(params.get('buscar') || '');
  const pagina = Number(params.get('pagina') || 1);
  const nivel = params.get('nivel') || '';
  const alerta = params.get('alerta') || '';
  const riesgo = useResumenRiesgo();
  const { data, isLoading, error, refetch } = useAfianzados({ pagina, buscar: params.get('buscar') || '', nivel, alerta });
  const r = riesgo.data;

  function cambiar(cambios) {
    const nuevo = new URLSearchParams(params);
    Object.entries(cambios).forEach(([k, v]) => (v ? nuevo.set(k, v) : nuevo.delete(k)));
    if (!('pagina' in cambios)) nuevo.delete('pagina');
    setParams(nuevo, { replace: true });
  }

  return (
    <div>
      <Encabezado
        titulo="Afianzados"
        descripcion={r?.perfil_actualizado
          ? `Perfil de riesgo de los distribuidores con fianza activa. Datos de Oracle al ${fechaHora(r.perfil_actualizado)}.`
          : 'Perfil de riesgo de los distribuidores con fianza activa. Aún no se cargan los datos de Oracle (IVE, mora, contragarantías).'}
      />
      {r && (
        <div className="kpis" style={{ marginBottom: '1rem' }}>
          <Kpi destacado icono={Users} pregunta="Afianzados activos" valor={numero(r.afianzados_activos)} contexto={`${qCorto(r.exposicion)} afianzado`}
            fuente="Afianzados con al menos una fianza activa" to="/afianzados" />
          <Kpi icono={ShieldAlert} pregunta="Riesgo alto" valor={numero(r.nivel_alto)} contexto="Reclamo o mora de más de 90 días" to="/afianzados?nivel=ALTO" />
          <Kpi icono={Gavel} pregunta="Con reclamo" valor={numero(r.con_reclamo)} contexto={`${q(r.por_recuperar)} por recuperar`} to="/afianzados?alerta=alerta_reclamo" />
          <Kpi icono={TrendingUp} pregunta="Mora de más de 60 días" valor={numero(r.con_atraso)} contexto={`${numero(r.con_atraso_90)} pasan de 90 días`} to="/afianzados?alerta=alerta_atraso" />
          <Kpi icono={ShieldOff} pregunta="Sobre Q300,000 sin contragarantía" valor={numero(r.sin_accesorio)} contexto={`${qCorto(r.exposicion_sin_accesorio)} expuesto`} to="/afianzados?alerta=alerta_accesorio" />
          <Kpi icono={Fingerprint} pregunta="IVE vencido" valor={numero(r.ive_vencido)}
            contexto={r.afianzados_activos ? `${Math.round((r.ive_vencido / r.afianzados_activos) * 100)} % de los activos` : ''} to="/afianzados?alerta=alerta_ive" />
        </div>
      )}

      <form className="filtros" onSubmit={(e) => { e.preventDefault(); cambiar({ buscar: texto.trim() }); }}>
        <input className="control buscar" placeholder="Nombre o código del afianzado" aria-label="Buscar afianzado" value={texto} onChange={(e) => setTexto(e.target.value)} />
        <select className="control" aria-label="Nivel de riesgo" value={nivel} onChange={(e) => cambiar({ nivel: e.target.value })}>
          <option value="">Todos los niveles</option>
          {Object.entries(NIVEL_RIESGO).map(([v, n]) => <option key={v} value={v}>{n.texto}</option>)}
        </select>
        <select className="control" aria-label="Alerta" value={alerta} onChange={(e) => cambiar({ alerta: e.target.value })}>
          {ALERTAS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
        </select>
        {(nivel || alerta || params.get('buscar')) && (
          <button type="button" className="btn btn-texto btn-sm" onClick={() => { setTexto(''); setParams({}, { replace: true }); }}>Quitar filtros</button>
        )}
      </form>

      {isLoading && <Cargando />}
      {error && <ErrorCarga error={error} reintentar={refetch} />}
      {!isLoading && !error && !data?.data?.length && <Vacio titulo="No hay afianzados con esos filtros" />}
      {data?.data?.length > 0 && (
        <>
          <div className="tabla-marco">
            <table className="tabla">
              <thead>
                <tr><th>Afianzado</th><th>Marcas</th><th>Riesgo</th><th>Alertas</th><th>Próximo vencimiento</th><th className="derecha">Exposición</th></tr>
              </thead>
              <tbody>
                {data.data.map((a) => (
                  <tr key={a.cliente_id} className="clic" onClick={() => navegar(`/afianzados/${a.cliente_id}`)}>
                    <td>
                      <Link className="principal-celda" to={`/afianzados/${a.cliente_id}`} onClick={(e) => e.stopPropagation()}>{nombre(a.nombre)}</Link>
                      <span className="secundaria-celda">Código {a.codigo} · desde {fecha(a.desde)}</span>
                    </td>
                    <td className="small">{a.marcas || ''}<span className="secundaria-celda">{a.polizas_activas} activas de {a.polizas_historicas}</span></td>
                    <td><Estado mapa={NIVEL_RIESGO} valor={a.nivel_riesgo} /></td>
                    <td><ChipsAlerta a={a} /></td>
                    <td className="small num">{fecha(a.proximo_vencimiento)}</td>
                    <td className="derecha num">
                      {q(a.exposicion)}
                      {a.contragarantia_monto > 0 && <span className="secundaria-celda">Contragarantía {qCorto(a.contragarantia_monto)}</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <Paginacion pagina={pagina} porPagina={30} total={data.count} onCambiar={(p) => cambiar({ pagina: String(p) })} />
        </>
      )}
    </div>
  );
}
