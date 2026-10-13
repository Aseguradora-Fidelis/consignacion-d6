import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { fijarMarcaEnVista, marcaEnVistaActual, supabase } from '../lib/supabase';
import { queryClient } from '../data/cliente';
import { esPersonal, puede } from './permisos';

const AuthContext = createContext(null);

async function cargarPerfil(user) {
  const [perfil, roles, grupos] = await Promise.all([
    supabase.from('user_profiles').select('full_name,email,role').eq('id', user.id).maybeSingle(),
    supabase.from('user_role_assignments').select('role').eq('user_id', user.id),
    supabase
      .from('user_grupos')
      .select('grupo:grupos_beneficiarios(id,codigo,nombre,beneficiarios:grupo_beneficiario_rel(beneficiario:beneficiarios(id,codigo_contacto,nombre)))')
      .eq('user_id', user.id),
  ]);
  for (const r of [perfil, roles, grupos]) if (r.error) throw r.error;

  const listaRoles = [...new Set([
    ...(roles.data || []).map((r) => r.role),
    ...(perfil.data?.role === 'admin' ? ['admin'] : []),
  ])];
  const marcas = (grupos.data || [])
    .map((g) => g.grupo)
    .filter(Boolean)
    .map((g) => ({
      id: g.id,
      codigo: g.codigo,
      nombre: g.nombre,
      beneficiarios: (g.beneficiarios || []).map((b) => b.beneficiario).filter(Boolean),
    }));

  return {
    id: user.id,
    email: perfil.data?.email || user.email,
    nombre: perfil.data?.full_name || user.email,
    roles: listaRoles,
    marcas,
    esPersonal: esPersonal(listaRoles),
    esMarca: !esPersonal(listaRoles) && marcas.length > 0,
  };
}

export function AuthProvider({ children }) {
  const [usuario, setUsuario] = useState(null);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState(null);
  // Enlace de invitacion o de recuperacion: la persona debe crear su contrasena.
  const [requiereClave, setRequiereClave] = useState(() => /type=(invite|recovery)/.test(window.location.hash));
  const [vista, setVista] = useState(marcaEnVistaActual);

  const hidratar = useCallback(async (session) => {
    if (!session?.user) {
      setUsuario(null);
      return;
    }
    try {
      setUsuario(await cargarPerfil(session.user));
      setError(null);
    } catch (e) {
      setError(e);
      setUsuario(null);
    }
  }, []);

  useEffect(() => {
    let activo = true;
    supabase.auth.getSession().then(async ({ data }) => {
      if (!activo) return;
      await hidratar(data.session);
      if (activo) setCargando(false);
    });
    const { data } = supabase.auth.onAuthStateChange((evento, session) => {
      if (evento === 'SIGNED_OUT') setUsuario(null);
      if (evento === 'PASSWORD_RECOVERY') setRequiereClave(true);
      if (evento === 'SIGNED_IN' || evento === 'USER_UPDATED') {
        // Fuera del callback para no bloquear el cliente de auth.
        setTimeout(() => hidratar(session), 0);
      }
    });
    return () => {
      activo = false;
      data.subscription.unsubscribe();
    };
  }, [hidratar]);

  // En modo reunion el personal se ve a si mismo como la marca elegida: mismo menu, mismas pantallas.
  const visible = useMemo(() => {
    if (!usuario) return null;
    if (!vista || !usuario.esPersonal) return { ...usuario, personalReal: usuario.esPersonal, enReunion: null };
    return {
      ...usuario,
      roles: ['beneficiario'],
      marcas: [vista],
      esPersonal: false,
      esMarca: true,
      personalReal: true,
      enReunion: vista,
    };
  }, [usuario, vista]);

  // Una marca sin personal real no puede usar el modo reunion: se limpia por si quedo guardado.
  useEffect(() => {
    if (usuario && !usuario.esPersonal && vista) {
      fijarMarcaEnVista(null);
      setVista(null);
    }
  }, [usuario, vista]);

  const valor = useMemo(() => ({
    usuario: visible,
    cargando,
    error,
    requiereClave,
    async cambiarClave(password) {
      const { error: e } = await supabase.auth.updateUser({ password });
      if (e) throw e;
      setRequiereClave(false);
      window.history.replaceState(null, '', window.location.pathname);
    },
    async ingresar(email, password) {
      const { data, error: e } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
      if (e) throw e;
      await hidratar(data.session);
    },
    async salir() {
      fijarMarcaEnVista(null);
      setVista(null);
      queryClient.clear();
      await supabase.auth.signOut();
      setUsuario(null);
    },
    // Elige la marca de la reunion (o null para volver a todas). Borra todo lo que habia en
    // memoria para que no quede nada de otra marca en pantalla.
    async elegirMarca(marca) {
      if (!marca) {
        fijarMarcaEnVista(null);
      } else {
        fijarMarcaEnVista({ id: marca.id, nombre: marca.nombre });
        const { data, error: e } = await supabase.from('grupos_beneficiarios')
          .select('id,codigo,nombre,beneficiarios:grupo_beneficiario_rel(beneficiario:beneficiarios(id,codigo_contacto,nombre))')
          .eq('id', marca.id).maybeSingle();
        if (e || !data) {
          fijarMarcaEnVista(null);
          setVista(null);
          throw e || new Error('No se pudo abrir la marca');
        }
        fijarMarcaEnVista({
          id: data.id, codigo: data.codigo, nombre: data.nombre,
          beneficiarios: (data.beneficiarios || []).map((b) => b.beneficiario).filter(Boolean),
        });
      }
      queryClient.clear();
      setVista(marcaEnVistaActual());
    },
    puede(permiso) {
      return Boolean(visible) && puede(visible.roles, permiso, { personalReal: visible.personalReal });
    },
  }), [visible, cargando, error, requiereClave, hidratar]);

  return <AuthContext.Provider value={valor}>{children}</AuthContext.Provider>;
}

// eslint-disable-next-line react-refresh/only-export-components
export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth debe usarse dentro de AuthProvider');
  return ctx;
}
