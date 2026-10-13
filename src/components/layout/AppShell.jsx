import { useEffect, useRef, useState } from 'react';
import { Link, NavLink, Outlet, matchPath, useLocation, useNavigate } from 'react-router-dom';
import {
  BookOpen, Bell, ClipboardList, FileMinus2, Gavel, GitCompareArrows, Handshake, Home, LogOut, Menu, Receipt,
  Scale, Settings, ShieldCheck, SlidersHorizontal, Store, Users,
} from 'lucide-react';
import { useAuth } from '../../auth/AuthProvider';
import { ROLES } from '../../auth/permisos';
import { useMarcarLeidas, useNotificaciones, useNotificacionesEnVivo } from '../../data/notificaciones';
import { useMarcasParaVista } from '../../data/operacion';
import { useToast } from '../ui/Toasts';
import { hace } from '../../lib/format';
import ErrorAplicacion from '../ErrorAplicacion';

// Menu agrupado por tipo de trabajo. Cada pagina sabe en que grupo esta para mostrarlo.
function navegacion({ usuario, puede }) {
  const grupos = [
    { grupo: null, items: [{ to: '/', texto: 'Inicio', icono: Home, fin: true }] },
    {
      grupo: usuario.esMarca ? 'Mi operación' : 'Operación',
      items: [
        puede('verCartera') && { to: '/cartera', texto: usuario.esMarca ? 'Mi cartera' : 'Cartera', icono: ShieldCheck },
        puede('verDistribuidores') && { to: '/distribuidores', texto: usuario.esMarca ? 'Mis distribuidores' : 'Distribuidores', icono: Store },
        puede('verAfianzados') && { to: '/afianzados', texto: 'Afianzados', icono: Users },
        puede('verAltas') && { to: '/altas', texto: puede('verExpedientes') ? 'Solicitudes de alta' : 'Altas', icono: ClipboardList },
        puede('verCartera') && { to: '/bajas', texto: 'Bajas', icono: FileMinus2 },
        puede('verReclamos') && { to: '/reclamos', texto: 'Reclamos', icono: Gavel },
      ].filter(Boolean),
    },
    {
      grupo: usuario.esMarca ? 'Pagos' : 'Cuentas',
      items: [
        // Lo que FISO le facturo a cada marca, con su saldo. Para la marca es lo que le paga a Fidelis.
        puede('verPagos') && { to: '/pagos', texto: usuario.esMarca ? 'Pagos a Fidelis' : 'Cuenta de cada marca', icono: Receipt },
        !usuario.esMarca && puede('verCuadre') && { to: '/cuadre', texto: 'Cuadre con FISO', icono: GitCompareArrows },
      ].filter(Boolean),
    },
    {
      grupo: usuario.esMarca ? 'Ayuda' : 'Referencia',
      items: [
        puede('verCondiciones') && { to: '/condiciones', texto: usuario.esMarca ? 'Condiciones de su marca' : 'Condiciones por marca', icono: usuario.esMarca ? Handshake : SlidersHorizontal },
        { to: '/glosario', texto: 'Glosario', icono: BookOpen },
        puede('administrar') && { to: '/admin', texto: 'Administración', icono: Settings },
      ].filter(Boolean),
    },
  ];
  return grupos.filter((g) => g.items.length);
}

function seccionActual(grupos, ruta) {
  for (const g of grupos) {
    for (const item of g.items) {
      if (item.to !== '/' && matchPath({ path: `${item.to}/*` }, ruta)) return { ...item, grupo: g.grupo };
    }
  }
  return null;
}

function Notificaciones({ userId }) {
  const [abierto, setAbierto] = useState(false);
  const ref = useRef(null);
  const { data = [] } = useNotificaciones(userId);
  const marcar = useMarcarLeidas(userId);
  const nuevas = data.filter((n) => !n.leido);

  useEffect(() => {
    if (!abierto) return undefined;
    const fuera = (e) => !ref.current?.contains(e.target) && setAbierto(false);
    document.addEventListener('mousedown', fuera);
    return () => document.removeEventListener('mousedown', fuera);
  }, [abierto]);

  return (
    <div style={{ position: 'relative' }} ref={ref}>
      <button
        className="btn btn-icono"
        aria-label={nuevas.length ? `Notificaciones, ${nuevas.length} sin leer` : 'Notificaciones'}
        aria-expanded={abierto}
        onClick={() => setAbierto((v) => !v)}
      >
        <Bell size={20} />
        {nuevas.length > 0 && <span className="punto-aviso" />}
      </button>
      {abierto && (
        <div className="desplegable" role="menu">
          <div className="row-between" style={{ padding: '0.75rem 1rem', borderBottom: '1px solid var(--borde)' }}>
            <strong>Notificaciones</strong>
            {nuevas.length > 0 && (
              <button className="btn btn-texto btn-sm" onClick={() => marcar.mutate(nuevas.map((n) => n.id))}>
                Marcar como leídas
              </button>
            )}
          </div>
          {data.length === 0 && <p className="muted small" style={{ padding: '1rem' }}>No tiene notificaciones.</p>}
          {data.map((n) => (
            <Link
              key={n.id}
              to={n.link || '/'}
              className={`desplegable-item ${n.leido ? '' : 'nueva'}`}
              onClick={() => {
                setAbierto(false);
                if (!n.leido) marcar.mutate([n.id]);
              }}
            >
              <strong style={{ display: 'block', fontSize: 'var(--t-sm)' }}>{n.titulo}</strong>
              <span className="small">{n.mensaje}</span>
              <span className="small muted" style={{ display: 'block', marginTop: '0.2rem' }}>{hace(n.created_at)}</span>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}

// Selector de marca para el personal. Con una marca elegida, la app entera muestra solo esa
// marca, igual que la ve el cliente. Pensado para reuniones con UMA, ADMOSA u otra marca.
function SelectorMarca() {
  const { usuario, elegirMarca } = useAuth();
  const marcas = useMarcasParaVista(usuario.personalReal);
  const navegar = useNavigate();
  const toast = useToast();
  const [cambiando, setCambiando] = useState(false);

  async function cambiar(id) {
    setCambiando(true);
    try {
      await elegirMarca(id ? marcas.data.find((m) => m.id === id) : null);
      navegar('/');
    } catch (e) {
      toast.error(e);
    } finally {
      setCambiando(false);
    }
  }

  return (
    <label className={`selector-marca ${usuario.enReunion ? 'activo' : ''}`}>
      <span className="selector-etiqueta">Ver</span>
      <select className="control" aria-label="Marca en pantalla" value={usuario.enReunion?.id || ''} disabled={cambiando || marcas.isLoading}
        onChange={(e) => cambiar(e.target.value)}>
        <option value="">Todas las marcas</option>
        {(marcas.data || []).map((m) => <option key={m.id} value={m.id}>Solo {m.nombre}</option>)}
      </select>
    </label>
  );
}

function iniciales(nombre) {
  return String(nombre || '?')
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0])
    .join('')
    .toUpperCase();
}

// En pantallas angostas el menu es un panel que se abre y se cierra.
const CONSULTA_MOVIL = '(max-width: 960px)';

function useEsMovil() {
  const [movil, setMovil] = useState(() => typeof window !== 'undefined' && Boolean(window.matchMedia?.(CONSULTA_MOVIL).matches));
  useEffect(() => {
    const mq = window.matchMedia?.(CONSULTA_MOVIL);
    if (!mq) return undefined;
    const cambiar = () => setMovil(mq.matches);
    mq.addEventListener('change', cambiar);
    return () => mq.removeEventListener('change', cambiar);
  }, []);
  return movil;
}

export default function AppShell() {
  const auth = useAuth();
  const { usuario, salir } = auth;
  const [menuAbierto, setMenuAbierto] = useState(false);
  const ubicacion = useLocation();
  const navegar = useNavigate();
  const esMovil = useEsMovil();
  const botonMenu = useRef(null);
  const sidebar = useRef(null);
  const grupos = navegacion(auth);
  const seccion = seccionActual(grupos, ubicacion.pathname);
  useNotificacionesEnVivo(usuario.enReunion ? null : usuario.id);

  useEffect(() => setMenuAbierto(false), [ubicacion.pathname]);

  // Menu movil: el foco entra al abrir, Escape lo cierra y el foco vuelve al boton.
  useEffect(() => {
    if (!menuAbierto) return undefined;
    sidebar.current?.querySelector('a, button')?.focus();
    const tecla = (e) => {
      if (e.key !== 'Escape') return;
      setMenuAbierto(false);
      botonMenu.current?.focus();
    };
    document.addEventListener('keydown', tecla);
    return () => document.removeEventListener('keydown', tecla);
  }, [menuAbierto]);

  const rolTexto = usuario.esMarca
    ? usuario.marcas.map((m) => m.nombre).join(', ')
    : usuario.roles.map((r) => ROLES[r] || r).join(', ');

  return (
    <div className="shell">
      <a className="saltar-contenido" href="#contenido">Saltar al contenido</a>
      <aside id="menu-principal" ref={sidebar} className={`sidebar ${menuAbierto ? 'abierto' : ''}`} aria-label="Navegación principal"
        inert={esMovil && !menuAbierto ? true : undefined}>
        <div className="sidebar-logo">
          <Link to="/" aria-label="Inicio">
            <img src="/brand/fidelis-fianzas.svg" alt="Fidelis Fianzas" />
          </Link>
        </div>
        <div className="sidebar-producto">Fianzas de consignación D-6</div>
        <nav>
          {grupos.map((g) => (
            <div key={g.grupo || 'inicio'}>
              {g.grupo && <div className="nav-grupo">{g.grupo}</div>}
              {g.items.map(({ to, texto, icono: Icono, fin }) => (
                <NavLink key={to} to={to} end={fin} className={({ isActive }) => `nav-item ${isActive ? 'activo' : ''}`}>
                  <Icono size={19} aria-hidden="true" />
                  {texto}
                </NavLink>
              ))}
            </div>
          ))}
        </nav>
        <div className="sidebar-pie">
          <span className="avatar" aria-hidden="true">{iniciales(usuario.nombre)}</span>
          <span className="quien">
            <strong title={usuario.nombre}>{usuario.nombre}</strong>
            <span className="rol" title={rolTexto}>{rolTexto || 'Sin acceso asignado'}</span>
          </span>
          <button
            className="btn btn-icono"
            aria-label="Cerrar sesión"
            title="Cerrar sesión"
            onClick={async () => {
              await salir();
              navegar('/ingresar');
            }}
          >
            <LogOut size={18} />
          </button>
        </div>
      </aside>
      <div className={`velo ${menuAbierto ? 'visible' : ''}`} onClick={() => setMenuAbierto(false)} />
      <div className="principal">
        <header className="topbar">
          <button ref={botonMenu} className="btn btn-icono boton-menu" aria-label="Menú" aria-expanded={menuAbierto}
            aria-controls="menu-principal" onClick={() => setMenuAbierto((v) => !v)}>
            <Menu size={22} aria-hidden="true" />
          </button>
          {seccion && (
            <span className="ceja" style={{ margin: 0 }}>
              <span className="icono-seccion" aria-hidden="true"><seccion.icono size={16} /></span>
              {seccion.grupo && <span>{seccion.grupo}</span>}
              {seccion.grupo && <span aria-hidden="true">/</span>}
              <strong style={{ color: 'var(--negro)', fontWeight: 500 }}>{seccion.texto}</strong>
            </span>
          )}
          <span className="espacio" />
          {usuario.personalReal && <SelectorMarca />}
          {!usuario.enReunion && <Notificaciones userId={usuario.id} />}
        </header>
        {usuario.enReunion && (
          <div className="banda-reunion" role="status">
            <span>
              <strong>Modo reunión con {usuario.enReunion.nombre}.</strong> Ve solo lo de esta marca, igual que la ve el cliente.
              Las demás marcas y la información interna de Fidelis están ocultas.
            </span>
            <button className="btn btn-secundario btn-sm" onClick={() => auth.elegirMarca(null).then(() => navegar('/'))}>Salir del modo reunión</button>
          </div>
        )}
        <main className="contenido" id="contenido" tabIndex={-1}>
          <ErrorAplicacion key={ubicacion.pathname}>
            <Outlet />
          </ErrorAplicacion>
        </main>
      </div>
    </div>
  );
}

export function SinPermiso() {
  return (
    <div className="vacio">
      <Scale size={32} aria-hidden="true" />
      <h3 style={{ marginTop: '1rem' }}>No tiene acceso a esta sección</h3>
      <p>Si lo necesita, pida a Administración que le asigne el permiso.</p>
      <Link className="btn btn-secundario" to="/" style={{ marginTop: '1rem' }}>Volver al inicio</Link>
    </div>
  );
}
