import { lazy, Suspense } from 'react';
import { Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { AuthProvider, useAuth } from './auth/AuthProvider';
import { supabaseConfigurado } from './lib/supabase';
import AppShell, { SinPermiso } from './components/layout/AppShell';
import { Aviso, Cargando } from './components/ui';
import Ingresar from './pages/Ingresar';
import Portal from './pages/Portal';
import ErrorAplicacion from './components/ErrorAplicacion';
import CrearClave from './pages/CrearClave';

const Inicio = lazy(() => import('./pages/Inicio'));
const Cartera = lazy(() => import('./pages/Cartera'));
const FianzaDetalle = lazy(() => import('./pages/FianzaDetalle'));
const Altas = lazy(() => import('./pages/Altas'));
const AltaNueva = lazy(() => import('./pages/AltaNueva'));
const AltaDetalle = lazy(() => import('./pages/AltaDetalle'));
const AltaCompletar = lazy(() => import('./pages/AltaCompletar'));
const Bajas = lazy(() => import('./pages/Bajas'));
const Pagos = lazy(() => import('./pages/Pagos'));
const PagosMes = lazy(() => import('./pages/PagosMes'));
const Admin = lazy(() => import('./pages/Admin'));
const Reclamos = lazy(() => import('./pages/Reclamos'));
const ReclamoDetalle = lazy(() => import('./pages/ReclamoDetalle'));
const Afianzados = lazy(() => import('./pages/Afianzados'));
const AfianzadoDetalle = lazy(() => import('./pages/AfianzadoDetalle'));
const Cuadre = lazy(() => import('./pages/Cuadre'));
const Distribuidores = lazy(() => import('./pages/Distribuidores'));
const Condiciones = lazy(() => import('./pages/Condiciones'));
const Glosario = lazy(() => import('./pages/Glosario'));

function SinConfiguracion() {
  return (
    <div className="publica">
      <div className="publica-cuerpo">
        <img src="/brand/fidelis-fianzas.svg" alt="Fidelis Fianzas" style={{ height: 40, marginBottom: '2rem' }} />
        <Aviso tono="atencion" titulo="Falta configurar la conexión">
          Defina <code>VITE_SUPABASE_URL</code> y <code>VITE_SUPABASE_ANON_KEY</code> en el archivo <code>.env</code> y vuelva a
          iniciar la aplicación. En desarrollo local use los valores que muestra <code>npx supabase status</code>.
        </Aviso>
      </div>
    </div>
  );
}

function Protegida({ permiso, children }) {
  const { usuario, cargando, puede, error } = useAuth();
  const ubicacion = useLocation();
  if (cargando) return <Cargando texto="Abriendo su sesión" />;
  if (!usuario) {
    return error
      ? <div className="publica-cuerpo"><Aviso tono="critico" titulo="No se pudo cargar su perfil">Intente ingresar de nuevo.</Aviso></div>
      : <Navigate to="/ingresar" replace state={{ desde: ubicacion.pathname }} />;
  }
  if (permiso && !puede(permiso)) return <SinPermiso />;
  return children;
}

function Rutas() {
  const { requiereClave, usuario } = useAuth();
  if (requiereClave && usuario) return <CrearClave />;
  return (
    <Routes>
      <Route path="/ingresar" element={<Ingresar />} />
      <Route path="/portal" element={<Portal />} />
      <Route element={<Protegida><AppShell /></Protegida>}>
        <Route index element={<Inicio />} />
        <Route path="cartera" element={<Protegida permiso="verCartera"><Cartera /></Protegida>} />
        <Route path="cartera/:id" element={<Protegida permiso="verCartera"><FianzaDetalle /></Protegida>} />
        <Route path="altas" element={<Protegida permiso="verAltas"><Altas /></Protegida>} />
        <Route path="altas/nueva" element={<Protegida permiso="solicitarAlta"><AltaNueva /></Protegida>} />
        <Route path="altas/:id" element={<Protegida permiso="verAltas"><AltaDetalle /></Protegida>} />
        <Route path="altas/:id/completar" element={<Protegida permiso="corregirAlta"><AltaCompletar /></Protegida>} />
        <Route path="bajas" element={<Protegida permiso="verCartera"><Bajas /></Protegida>} />
        <Route path="pagos" element={<Protegida permiso="verPagos"><Pagos /></Protegida>} />
        <Route path="pagos/:marcaId/:periodo" element={<Protegida permiso="verPagos"><PagosMes /></Protegida>} />
        {/* Enlaces de avisos anteriores a la migracion 044. */}
        <Route path="cuenta-por-cobrar/*" element={<Navigate to="/pagos" replace />} />
        <Route path="admin" element={<Protegida permiso="administrar"><Admin /></Protegida>} />
        <Route path="reclamos" element={<Protegida permiso="verReclamos"><Reclamos /></Protegida>} />
        <Route path="reclamos/:id" element={<Protegida permiso="verReclamos"><ReclamoDetalle /></Protegida>} />
        <Route path="afianzados" element={<Protegida permiso="verAfianzados"><Afianzados /></Protegida>} />
        <Route path="afianzados/:id" element={<Protegida permiso="verAfianzados"><AfianzadoDetalle /></Protegida>} />
        <Route path="cuadre" element={<Protegida permiso="verCuadre"><Cuadre /></Protegida>} />
        <Route path="distribuidores" element={<Protegida permiso="verDistribuidores"><Distribuidores /></Protegida>} />
        <Route path="condiciones" element={<Protegida permiso="verCondiciones"><Condiciones /></Protegida>} />
        <Route path="glosario" element={<Glosario />} />
        <Route path="*" element={<div className="vacio"><h3>Esta página no existe</h3><p>Revise la dirección o vuelva al inicio.</p></div>} />
      </Route>
    </Routes>
  );
}

export default function App() {
  if (!supabaseConfigurado) return <SinConfiguracion />;
  return (
    <ErrorAplicacion>
      <AuthProvider>
        <Suspense fallback={<Cargando />}>
          <Rutas />
        </Suspense>
      </AuthProvider>
    </ErrorAplicacion>
  );
}
