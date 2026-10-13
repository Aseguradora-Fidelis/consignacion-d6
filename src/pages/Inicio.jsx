import { Link, useNavigate } from 'react-router-dom';
import {
  ArrowRight, CalendarClock, CheckCircle2, FileMinus2, Plus, Receipt, RefreshCw, ShieldAlert, ShieldCheck, Wallet,
} from 'lucide-react';
import { useAuth } from '../auth/AuthProvider';
import { Aviso, Cargando, ErrorCarga, Estado, Kpi, Panel } from '../components/ui';
import { useAltas } from '../data/altas';
import { useCarteraPorMarca, usePorVencer, useResumenCartera, useVencimientos } from '../data/cartera';
import { resumirCuenta, useCuentaMarca } from '../data/cobros';
import { useReclamos } from '../data/reclamos';
import { useResumenRiesgo } from '../data/perfil';
import { useCuadreFiso } from '../data/operacion';
import { ESTADO_ALTA, ESTADO_RECLAMO, ESTADOS_EN_TRAMITE, SIGUIENTE_PASO_MARCA } from '../domain/estados';
import { diasHasta, fecha, fechaHora, hace, mes, nombre, numero, q, qCorto } from '../lib/format';

const ACTIVAS = ['VIGENTE', 'POR_RENOVAR', 'EN_BAJA'];

function sumar(filas, estados, campo) {
  return (filas || []).filter((f) => estados.includes(f.estado)).reduce((t, f) => t + Number(f[campo] || 0), 0);
}

// ---------------------------------------------------------------------------
// Indicadores
// ---------------------------------------------------------------------------
function Indicadores({ marcaId, esMarca }) {
  const cartera = useResumenCartera(marcaId);
  const cuenta = useCuentaMarca({ marcaId: marcaId || '' });
  if (cartera.isLoading) return <Cargando />;
  if (cartera.error) return <ErrorCarga error={cartera.error} reintentar={cartera.refetch} />;
  const d = cartera.data;
  const { saldo, vencido, saldoAl } = resumirCuenta(cuenta.data);
  return (
    <div className="kpis">
      <Kpi
        destacado
        icono={ShieldCheck}
        pregunta={esMarca ? 'Fianzas activas' : 'Fianzas D-6 activas'}
        valor={numero(sumar(d, ACTIVAS, 'polizas'))}
        contexto={`${numero(sumar(d, ACTIVAS, 'afianzados'))} ${esMarca ? 'distribuidores' : 'afianzados'}`}
        fuente="Cartera D-6, pólizas con vigencia a la fecha"
        to="/cartera?estado=ACTIVAS"
      />
      <Kpi
        icono={Wallet}
        pregunta="Monto afianzado"
        valor={qCorto(sumar(d, ACTIVAS, 'monto'))}
        contexto="Suma de las fianzas activas"
        fuente="Cartera D-6, monto afianzado de pólizas activas"
      />
      <Kpi
        icono={CalendarClock}
        pregunta="Vencen en 60 días"
        valor={numero(sumar(d, ['POR_RENOVAR'], 'polizas'))}
        contexto="Requieren renovación"
        fuente="Cartera D-6, vigencia hasta dentro de 60 días"
        to="/cartera?estado=POR_RENOVAR"
      />
      <Kpi
        icono={Receipt}
        pregunta={esMarca ? 'Saldo por pagar' : 'Saldo de las marcas'}
        valor={q(saldo)}
        contexto={vencido > 0 ? `${q(vencido)} vencido` : 'Nada vencido'}
        fuente={saldoAl ? `Facturas D-6 de FISO, saldo al ${fechaHora(saldoAl)}` : 'Facturas D-6 de FISO'}
        to="/pagos"
      />
    </div>
  );
}

// ---------------------------------------------------------------------------
// Lo que requiere atencion, por rol
// ---------------------------------------------------------------------------
function Tareas({ tareas, cargando, vacio = 'Todo al día. No hay pendientes para usted.' }) {
  if (cargando) return <Cargando />;
  const visibles = tareas.filter((t) => t.n > 0);
  if (!visibles.length) {
    return (
      <div className="al-dia">
        <CheckCircle2 size={22} aria-hidden="true" />
        {vacio}
      </div>
    );
  }
  return (
    <ul className="tareas">
      {visibles.map((t) => (
        <li key={t.titulo}>
          <Link to={t.to} className={`tarea ${t.tono || 'activo'}`}>
            <span className="tarea-num">{t.n}</span>
            <span className="tarea-texto">
              <strong>{t.titulo}</strong>
              <span className="sub">{t.detalle}</span>
            </span>
            <ArrowRight size={18} className="flecha" aria-hidden="true" />
          </Link>
        </li>
      ))}
    </ul>
  );
}

function useTareas() {
  const { usuario, puede } = useAuth();
  const esPersonal = puede('verExpedientes');
  const altas = useAltas({ esPersonal, estados: ESTADOS_EN_TRAMITE });
  const marcaUnica = usuario.esMarca && usuario.marcas.length === 1 ? usuario.marcas[0].id : '';
  const cuenta = useCuentaMarca({ marcaId: marcaUnica });
  const cartera = useResumenCartera(marcaUnica || null);
  const reclamos = useReclamos({ estado: 'ABIERTOS' });
  const cuadre = useCuadreFiso(puede('verCuadre'));
  const a = altas.data || [];
  const rec = reclamos.data || [];
  const meses = cuenta.data || [];
  const vencidos = meses.filter((m) => m.estado === 'VENCIDO');
  const porPagar = meses.filter((m) => ['PENDIENTE', 'PARCIAL'].includes(m.estado));
  const suma = (filas) => q(filas.reduce((t, m) => t + Number(m.saldo || 0), 0));
  const tareas = [];

  if (esPersonal) {
    // El personal no trabaja casos en la app: estas son las cosas para consultar.
    const recibidas = a.filter((x) => x.estado_operativo === 'EXPEDIENTE_RECIBIDO');
    const pep = recibidas.filter((x) => x.es_pep).length;
    const c = cuadre.data || [];
    tareas.push(
      { n: recibidas.length, titulo: 'Solicitudes recibidas', detalle: pep ? `${pep} con persona expuesta políticamente` : 'Con su expediente completo, sin fianza en FISO todavía', to: '/altas?estado=RECIBIDAS', tono: pep ? 'critico' : 'activo' },
      { n: c.filter((x) => x.tipo === 'RECIBIDA_SIN_EMISION').length, titulo: 'Recibidas hace más de 30 días', detalle: 'Sin fianza emitida en FISO', to: '/cuadre?tipo=RECIBIDA_SIN_EMISION', tono: 'atencion' },
      { n: c.filter((x) => x.tipo === 'BAJA_PENDIENTE_EN_FISO').length, titulo: 'Bajas pendientes en FISO', detalle: 'Su fecha ya pasó y FISO no las cancela', to: '/cuadre?tipo=BAJA_PENDIENTE_EN_FISO', tono: 'critico' },
      { n: rec.length, titulo: 'Reclamos abiertos', detalle: `${q(rec.reduce((t, x) => t + Number(x.monto_reclamado || 0), 0))} reclamado`, to: '/reclamos', tono: 'atencion' },
      { n: vencidos.length, titulo: 'Meses vencidos de las marcas', detalle: suma(vencidos), to: '/pagos', tono: 'critico' },
    );
  } else {
    const llenando = a.filter((x) => ['BORRADOR', 'IVE_PENDIENTE'].includes(x.estado_operativo));
    const conFaltantes = a.filter((x) => x.estado_operativo === 'EXPEDIENTE_RECIBIDO' && Array.isArray(x.faltantes) && x.faltantes.length);
    tareas.push(
      { n: conFaltantes.length, titulo: 'Recibidas con documentos pendientes', detalle: 'Súbalos usted o envíe un enlace nuevo al distribuidor', to: '/altas', tono: 'critico' },
      { n: llenando.length, titulo: 'El distribuidor está llenando', detalle: 'Puede ver su avance y adelantar datos', to: '/altas', tono: 'atencion' },
      { n: vencidos.length, titulo: 'Pagos vencidos', detalle: suma(vencidos), to: '/pagos', tono: 'critico' },
      { n: porPagar.length, titulo: 'Meses por pagar', detalle: suma(porPagar), to: '/pagos', tono: 'activo' },
      { n: sumar(cartera.data, ['POR_RENOVAR'], 'polizas'), titulo: 'Fianzas que vencen en 60 días', detalle: 'Renuévelas desde Vencen pronto o desde la fianza', to: '/cartera?estado=POR_RENOVAR', tono: 'atencion' },
      { n: rec.length, titulo: 'Reclamos en curso', detalle: 'Avisos y reclamos que presentó', to: '/reclamos', tono: 'activo' },
    );
  }
  return { tareas, cargando: altas.isLoading || cuenta.isLoading };
}

// ---------------------------------------------------------------------------
// Graficos
// ---------------------------------------------------------------------------
function CarteraPorMarca() {
  const { data, isLoading } = useCarteraPorMarca();
  if (isLoading) return <Cargando />;
  const filas = (data || []).filter((m) => Number(m.monto) > 0);
  if (!filas.length) return <p className="muted">Sin fianzas activas.</p>;
  const maximo = Math.max(...filas.map((m) => Number(m.monto)));
  const total = filas.reduce((t, m) => t + Number(m.monto), 0);
  return (
    <>
      <div className="barras" role="list">
        {filas.map((m) => {
          const contenido = (
            <>
              <span className="etiqueta-barra" title={m.marca_nombre}>{m.marca_nombre}</span>
              <span className="barra-pista" aria-hidden="true">
                <span className="barra-valor" style={{ display: 'block', width: `${(Number(m.monto) / maximo) * 100}%` }} />
              </span>
              <span className="cifra">
                {qCorto(m.monto)}
                <small>{numero(m.polizas)} fianzas · {((Number(m.monto) / total) * 100).toFixed(0)} %</small>
              </span>
            </>
          );
          return m.marca_id
            ? <Link key={m.marca_id} role="listitem" className="barra-fila" to={`/cartera?marca=${m.marca_id}&estado=ACTIVAS`}>{contenido}</Link>
            : <div key="sin" role="listitem" className="barra-fila">{contenido}</div>;
        })}
      </div>
      <div className="leyenda"><span>Monto afianzado activo por marca</span></div>
    </>
  );
}

function Vencimientos() {
  const { data, isLoading } = useVencimientos(6);
  if (isLoading) return <Cargando />;
  const maximo = Math.max(1, ...(data || []).map((m) => m.polizas));
  return (
    <>
      <div className="columnas-mes" role="list">
        {(data || []).map((m) => (
          <div key={m.clave} className="columna-mes" role="listitem" title={`${mes(m.fecha)}: ${m.polizas} fianzas, ${q(m.monto)}`}>
            <span className="n">{m.polizas}</span>
            <span className={`cuerpo ${m.polizas ? '' : 'cero'}`} style={{ height: `${(m.polizas / maximo) * 72}%` }} />
            <span>{mes(m.fecha).slice(0, 3)}</span>
          </div>
        ))}
      </div>
      <div className="leyenda"><span>Fianzas activas que vencen cada mes</span></div>
    </>
  );
}

function PorVencer({ renovar }) {
  const { data, isLoading } = usePorVencer(60, 5);
  if (isLoading) return <Cargando />;
  if (!data?.length) return <div className="al-dia"><CheckCircle2 size={20} aria-hidden="true" /> Ninguna vence en 60 días.</div>;
  return (
    <ul className="tareas">
      {data.map((f) => {
        const dias = diasHasta(f.vigencia_hasta);
        return (
          <li key={f.id} className={renovar ? 'tarea-con-accion' : undefined}>
            <Link to={`/cartera/${f.id}`} className={`tarea ${dias <= 15 ? 'critico' : 'atencion'}`}>
              <span className="tarea-num" title="Días para vencer">{dias}</span>
              <span className="tarea-texto">
                <strong>{nombre(f.cliente_nombre)}</strong>
                <span className="sub">Fianza {f.fianza} · vence el {fecha(f.vigencia_hasta)}</span>
              </span>
              {!renovar && <ArrowRight size={18} className="flecha" aria-hidden="true" />}
            </Link>
            {renovar && (
              <Link className="btn btn-secundario btn-sm" to={`/altas/nueva?renovar=${f.id}`}
                aria-label={`Renovar la fianza ${f.fianza} de ${nombre(f.cliente_nombre)}`}>
                <RefreshCw size={16} aria-hidden="true" /> Renovar
              </Link>
            )}
          </li>
        );
      })}
    </ul>
  );
}

function RiesgoCartera() {
  const { data: r, isLoading } = useResumenRiesgo();
  if (isLoading) return <Cargando />;
  if (!r) return null;
  const total = Number(r.afianzados_activos) || 1;
  const filas = [
    ['Riesgo alto', r.nivel_alto, '/afianzados?nivel=ALTO'],
    ['Riesgo medio', r.nivel_medio, '/afianzados?nivel=MEDIO'],
    ['Riesgo bajo', r.nivel_bajo, '/afianzados?nivel=BAJO'],
    ['IVE vencido', r.ive_vencido, '/afianzados?alerta=alerta_ive'],
    ['Sin contragarantía', r.sin_accesorio, '/afianzados?alerta=alerta_accesorio'],
    ['Mora de más de 60 días', r.con_atraso, '/afianzados?alerta=alerta_atraso'],
  ];
  return (
    <>
      <div className="barras" role="list">
        {filas.map(([texto, n, to]) => (
          <Link key={texto} role="listitem" className="barra-fila" to={to}>
            <span className="etiqueta-barra">{texto}</span>
            <span className="barra-pista" aria-hidden="true">
              <span className="barra-valor" style={{ display: 'block', width: `${(Number(n) / total) * 100}%` }} />
            </span>
            <span className="cifra">{numero(n)}<small>{Math.round((Number(n) / total) * 100)} % de {numero(total)}</small></span>
          </Link>
        ))}
      </div>
      <div className="leyenda"><span>Afianzados con fianza activa</span></div>
    </>
  );
}

function ReclamosRecientes() {
  const { data, isLoading } = useReclamos({ estado: 'ABIERTOS' });
  if (isLoading) return <Cargando />;
  if (!data?.length) return <div className="al-dia"><CheckCircle2 size={20} aria-hidden="true" /> No hay reclamos abiertos.</div>;
  return (
    <ul className="tareas">
      {data.slice(0, 5).map((x) => (
        <li key={x.id}>
          <Link className="tarea" to={`/reclamos/${x.id}`}>
            <span className="tarea-texto"><strong>{nombre(x.afianzado_nombre)}</strong><span className="sub">{x.numero} · {q(x.monto_reclamado)}</span></span>
            <Estado mapa={ESTADO_RECLAMO} valor={x.estado} />
          </Link>
        </li>
      ))}
    </ul>
  );
}

function AltasMarca() {
  const { data, isLoading, error } = useAltas({ esPersonal: false, estados: ESTADOS_EN_TRAMITE });
  if (isLoading) return <Cargando />;
  if (error) return <ErrorCarga error={error} />;
  if (!data?.length) {
    return <p className="muted" style={{ padding: '1.25rem 1.35rem' }}>No tiene altas en trámite. Cuando solicite una, verá aquí en qué paso va.</p>;
  }
  return (
    <div className="tabla-marco">
      <table className="tabla">
        <thead><tr><th>Distribuidor</th><th>Estado</th><th>Qué sigue</th><th className="derecha">Monto</th></tr></thead>
        <tbody>
          {data.slice(0, 8).map((a) => (
            <tr key={a.id}>
              <td>
                <Link to={`/altas/${a.id}`} className="principal-celda">{nombre(a.afianzado_nombre)}</Link>
                <span className="secundaria-celda">{a.numero_solicitud} · {hace(a.created_at)}</span>
              </td>
              <td><Estado mapa={ESTADO_ALTA} valor={a.estado_operativo} /></td>
              <td className="small">{SIGUIENTE_PASO_MARCA[a.estado_operativo]}</td>
              <td className="derecha num">{q(a.monto_solicitado)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Pagina
// ---------------------------------------------------------------------------
export default function Inicio() {
  const { usuario, puede } = useAuth();
  const navegar = useNavigate();
  const { tareas, cargando } = useTareas();

  if (!usuario.esPersonal && !usuario.marcas.length) {
    return (
      <Aviso tono="atencion" titulo="Su cuenta aún no tiene acceso asignado">
        Administración debe asignarle una marca o un rol. Avise a su contacto en Fidelis.
      </Aviso>
    );
  }

  const primerNombre = String(usuario.nombre || '').split(' ')[0];
  const hora = new Date().getHours();
  const saludo = hora < 12 ? 'Buenos días' : hora < 19 ? 'Buenas tardes' : 'Buenas noches';
  const hoy = new Date().toLocaleDateString('es-GT', { weekday: 'long', day: 'numeric', month: 'long' });
  const marcaUnica = usuario.esMarca && usuario.marcas.length === 1 ? usuario.marcas[0] : null;

  return (
    <div>
      <div className="encabezado">
        <div>
          <p className="small muted" style={{ margin: 0 }}>{hoy.charAt(0).toUpperCase() + hoy.slice(1)}</p>
          <h1 style={{ marginTop: '0.25rem' }}>{saludo}, {primerNombre}</h1>
          <p>{usuario.esMarca ? `Cartera D-6 de ${usuario.marcas.map((m) => m.nombre).join(', ')}` : 'Fianzas de consignación D-6'}</p>
        </div>
        <div className="row">
          {puede('solicitarBaja') && (
            <Link className="btn btn-secundario" to="/cartera?estado=ACTIVAS">
              <FileMinus2 size={18} aria-hidden="true" /> Pedir una baja
            </Link>
          )}
          {puede('solicitarAlta') && (
            <button className="btn btn-primario" onClick={() => navegar('/altas/nueva')}>
              <Plus size={18} aria-hidden="true" /> Solicitar alta
            </button>
          )}
        </div>
      </div>

      <Indicadores marcaId={marcaUnica?.id} esMarca={usuario.esMarca} />

      {usuario.esMarca ? (
        <div className="tablero">
          <div className="c-5">
            <Panel titulo="Requiere su atención" subtitulo="Lo que está esperando una acción suya" sinRelleno>
              <Tareas tareas={tareas} cargando={cargando} />
            </Panel>
          </div>
          <div className="c-7">
            <Panel titulo="Sus altas en trámite" accion={<Link to="/altas" className="small">Ver todas</Link>} sinRelleno>
              <AltasMarca />
            </Panel>
          </div>
          <div className="c-7">
            <Panel titulo="Vencimientos de los próximos 6 meses"><Vencimientos /></Panel>
          </div>
          <div className="c-5">
            <Panel titulo="Vencen pronto" accion={<Link to="/cartera?estado=POR_RENOVAR" className="small">Ver todas</Link>} sinRelleno>
              <PorVencer renovar={puede('solicitarAlta')} />
            </Panel>
          </div>
        </div>
      ) : (
        <div className="tablero">
          <div className="c-4">
            <Panel titulo="Para consultar" subtitulo="Lo que llegó de las marcas y lo que no cuadra con FISO" sinRelleno>
              <Tareas tareas={tareas} cargando={cargando} vacio="No hay nada nuevo para consultar." />
            </Panel>
          </div>
          {puede('verAfianzados') && (
            <div className="c-4">
              <Panel titulo="Riesgo de los afianzados" subtitulo="Clic para ver quiénes son"
                accion={<Link to="/afianzados" className="small"><ShieldAlert size={16} aria-hidden="true" /> Perfiles</Link>}>
                <RiesgoCartera />
              </Panel>
            </div>
          )}
          <div className="c-4">
            <Panel titulo="Vencen pronto" accion={<Link to="/cartera?estado=POR_RENOVAR" className="small">Ver todas</Link>} sinRelleno>
              <PorVencer renovar={puede('solicitarAlta')} />
            </Panel>
          </div>
          <div className="c-5">
            <Panel titulo="Cartera activa por marca" accion={<Link to="/cartera?estado=ACTIVAS" className="small">Ver cartera</Link>}>
              <CarteraPorMarca />
            </Panel>
          </div>
          <div className="c-4">
            <Panel titulo="Vencimientos de los próximos 6 meses"><Vencimientos /></Panel>
          </div>
          <div className="c-3">
            <Panel titulo="Reclamos abiertos" accion={<Link to="/reclamos" className="small">Ver todos</Link>} sinRelleno>
              <ReclamosRecientes />
            </Panel>
          </div>
        </div>
      )}
    </div>
  );
}
