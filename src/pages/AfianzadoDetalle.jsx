import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, CalendarClock, CheckCircle2, Landmark, ShieldCheck, Wallet, XCircle } from 'lucide-react';
import { Cargando, Datos, Encabezado, ErrorCarga, Estado, Kpi, Panel, Vacio } from '../components/ui';
import HistorialAfianzado from '../components/HistorialAfianzado';
import { TablaVinculados } from '../components/ReferenciaDistribuidor';
import { useAfianzado } from '../data/perfil';
import { useVinculadosCliente } from '../data/operacion';
import { useReclamos } from '../data/reclamos';
import { ESTADO_ALTA, ESTADO_POLIZA, ESTADO_RECLAMO, NIVEL_RIESGO, TIPO_PERSONA } from '../domain/estados';
import { aFecha, fecha, fechaHora, nombre, numero, q, qCorto } from '../lib/format';

function anios(desde) {
  const d = aFecha(desde);
  if (!d) return '';
  const a = (Date.now() - d.getTime()) / (365.25 * 86_400_000);
  return a < 1 ? 'menos de un año' : `${Math.floor(a)} ${Math.floor(a) === 1 ? 'año' : 'años'}`;
}

function Regla({ ok, texto, detalle }) {
  return (
    <li className="tarea" style={{ cursor: 'default' }}>
      {ok
        ? <CheckCircle2 size={20} aria-hidden="true" style={{ color: 'var(--ok)', flexShrink: 0 }} />
        : <XCircle size={20} aria-hidden="true" style={{ color: 'var(--critico)', flexShrink: 0 }} />}
      <span className="tarea-texto"><strong>{texto}</strong>{detalle && <span className="sub">{detalle}</span>}</span>
    </li>
  );
}

export default function AfianzadoDetalle() {
  const { id } = useParams();
  const { data: a, isLoading, error, refetch } = useAfianzado(id);
  const reclamos = useReclamos({ clienteId: id });
  const vinculados = useVinculadosCliente(id);
  const volver = <Link to="/afianzados" className="volver"><ArrowLeft size={16} aria-hidden="true" /> Afianzados</Link>;

  if (isLoading) return <Cargando />;
  if (error) return <>{volver}<ErrorCarga error={error} reintentar={refetch} /></>;
  if (!a) return <>{volver}<Vacio titulo="No encontramos este afianzado" /></>;

  const ive = a.ive_fecha_renovacion ? `${a.alerta_ive ? 'Venció' : 'Vence'} el ${fecha(a.ive_fecha_renovacion)}` : 'Sin registro de renovación';

  return (
    <div>
      <Encabezado volver={volver} titulo={nombre(a.nombre)}
        descripcion={`Código ${a.codigo}${a.nit ? ` · NIT ${a.nit}` : ''} · ${TIPO_PERSONA[a.tipo_persona] || ''} · cliente desde ${fecha(a.desde)} (${anios(a.desde)})`}
        acciones={<Estado mapa={NIVEL_RIESGO} valor={a.nivel_riesgo} />}
      />

      <div className="kpis">
        <Kpi destacado icono={ShieldCheck} pregunta="Exposición actual" valor={q(a.exposicion)}
          contexto={`${a.polizas_activas} fianzas activas con ${a.marcas_activas} ${a.marcas_activas === 1 ? 'marca' : 'marcas'}`} />
        <Kpi icono={Landmark} pregunta="Contragarantía vigente" valor={q(a.contragarantia_monto)}
          contexto={a.contragarantia_tipos || (a.exposicion > 300000 ? 'Exigible: supera Q300,000' : 'No exigible')} />
        <Kpi icono={Wallet} pregunta="Saldo atrasado" valor={q(a.saldo_atrasado)}
          contexto={a.max_dias_atraso ? `${a.max_dias_atraso} días de atraso máximo` : 'Al día'} />
        <Kpi icono={CalendarClock} pregunta="Próximo vencimiento" valor={fecha(a.proximo_vencimiento) || 'Sin activas'}
          contexto={`${a.polizas_historicas} fianzas en su historia`} />
      </div>

      <div className="tablero">
        <div className="c-5 columna">
          <Panel titulo="Por qué este nivel de riesgo" subtitulo="Reglas a la vista: ninguna se calcula a escondidas" sinRelleno>
            <ul className="tareas">
              <Regla ok={!a.alerta_reclamo} texto={a.alerta_reclamo ? 'Tiene reclamos' : 'Sin reclamos'}
                detalle={`${a.reclamos_oracle} en Oracle · ${a.reclamos_app} en la app${a.por_recuperar > 0 ? ` · ${q(a.por_recuperar)} por recuperar` : ''}`} />
              <Regla ok={!a.alerta_atraso_90} texto={a.alerta_atraso_90 ? 'Mora de más de 90 días' : 'Sin mora mayor a 90 días'}
                detalle={a.saldo_atrasado_90 > 0 ? q(a.saldo_atrasado_90) : null} />
              <Regla ok={!a.alerta_atraso} texto={a.alerta_atraso ? 'Mora de más de 60 días' : 'Sin mora mayor a 60 días'}
                detalle={`Cuenta por cobrar ${q(a.saldo)}, atrasado ${q(a.saldo_atrasado)}. Hasta 60 días es el plazo normal de pago de la marca.`} />
              <Regla ok={!a.alerta_accesorio} texto={a.alerta_accesorio ? 'Supera Q300,000 sin contragarantía' : 'Contragarantía conforme a la exposición'}
                detalle={`Exposición ${q(a.exposicion)} · contragarantía ${q(a.contragarantia_monto)}`} />
              <Regla ok={!a.alerta_ive} texto={a.alerta_ive ? 'IVE vencido' : 'IVE vigente'}
                detalle={`${ive}${a.ive_verificado ? ' · verificado' : ''}`} />
            </ul>
            <div className="panel-pie muted">
              {a.perfil_actualizado ? `Datos de Oracle al ${fechaHora(a.perfil_actualizado)}.` : 'Sin datos de Oracle para este afianzado.'}
              {a.otras_fianzas_vigentes > 0 && ` Tiene además ${a.otras_fianzas_vigentes} fianzas de otras clases por ${qCorto(a.otras_fianzas_monto)}.`}
              {a.cumulo ? ` Cúmulo autorizado ${q(a.cumulo)}.` : ''}
            </div>
          </Panel>

          <Panel titulo="Movimientos" subtitulo="Altas, bajas, reclamos y emisiones en orden" sinRelleno>
            <HistorialAfianzado clienteId={id} />
          </Panel>

          <Panel titulo="Reclamos" sinRelleno>
            {(reclamos.data || []).length === 0 ? <p className="al-dia">Sin reclamos registrados en la app.</p> : (
              <ul className="tareas">
                {reclamos.data.map((r) => (
                  <li key={r.id}>
                    <Link className="tarea" to={`/reclamos/${r.id}`}>
                      <span className="tarea-texto"><strong>{r.numero} · {q(r.monto_reclamado)}</strong><span className="sub">Fianza {r.fianza} · {fecha(r.created_at)}</span></span>
                      <Estado mapa={ESTADO_RECLAMO} valor={r.estado} />
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </Panel>
        </div>

        <div className="c-7 columna">
          <Panel titulo="Fianzas" subtitulo={`${a.polizas_activas} activas, ${a.canceladas} canceladas, monto máximo ${qCorto(a.monto_maximo)}`} sinRelleno>
            <div className="tabla-marco">
              <table className="tabla">
                <thead><tr><th>Fianza</th><th>Marca</th><th>Vigencia</th><th>Estado</th><th className="derecha">Monto</th></tr></thead>
                <tbody>
                  {a.polizas.map((p) => (
                    <tr key={p.id}>
                      <td><Link className="principal-celda num" to={`/cartera/${p.id}`}>{p.fianza}</Link>{p.endoso > 0 && <span className="secundaria-celda">Endoso {p.endoso}</span>}</td>
                      <td className="small">{p.marca_nombre || nombre(p.beneficiario_nombre)}</td>
                      <td className="small num">{fecha(p.vigencia_desde)} al {fecha(p.vigencia_hasta)}</td>
                      <td><Estado mapa={ESTADO_POLIZA} valor={p.estado} /></td>
                      <td className="derecha num">{q(p.monto_original)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Panel>

          {a.altas.length > 0 && (
            <Panel titulo="Solicitudes de alta" sinRelleno>
              <ul className="tareas">
                {a.altas.map((s) => (
                  <li key={s.id}>
                    <Link className="tarea" to={`/altas/${s.id}`}>
                      <span className="tarea-texto"><strong>{s.numero_solicitud} · {q(s.monto_solicitado)}</strong><span className="sub">{nombre(s.beneficiario_nombre)} · {fecha(s.created_at)}</span></span>
                      <Estado mapa={ESTADO_ALTA} valor={s.estado_operativo} />
                    </Link>
                  </li>
                ))}
              </ul>
            </Panel>
          )}

          <Panel titulo="Posibles vinculados"
            subtitulo={vinculados.data?.length
              ? `Suman ${q(vinculados.data.reduce((t, v) => t + Number(v.exposicion || 0), 0) + Number(a.exposicion || 0))} con este afianzado`
              : 'Mismo teléfono, dirección, patente o apellidos en el mismo municipio'}
            sinRelleno={vinculados.data?.length > 0}>
            {vinculados.isLoading ? <Cargando /> : <TablaVinculados vinculados={vinculados.data} />}
          </Panel>

          <Panel titulo="Datos de contacto y relación">
            <Datos items={[
              ['Pólizas en su historia', numero(a.polizas_historicas)],
              ['Cliente desde', `${fecha(a.desde)} (${anios(a.desde)})`],
              ['Marcas con las que opera hoy', a.marcas],
              ['IVE', ive],
            ]} />
          </Panel>
        </div>
      </div>
    </div>
  );
}
