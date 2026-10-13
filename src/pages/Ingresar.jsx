import { useState } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { Aviso, Campo } from '../components/ui';
import { mensajeError } from '../lib/errores';
import { supabase } from '../lib/supabase';

export default function Ingresar() {
  const { usuario, ingresar } = useAuth();
  const navegar = useNavigate();
  const ubicacion = useLocation();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [aviso, setAviso] = useState('');
  const [enviando, setEnviando] = useState(false);

  if (usuario) return <Navigate to={ubicacion.state?.desde || '/'} replace />;

  async function enviar(e) {
    e.preventDefault();
    setError('');
    setEnviando(true);
    try {
      await ingresar(email, password);
      navegar(ubicacion.state?.desde || '/', { replace: true });
    } catch (err) {
      setError(mensajeError(err));
    } finally {
      setEnviando(false);
    }
  }

  async function recuperar() {
    setError('');
    if (!email.trim()) {
      setError('Escriba su correo y vuelva a pedir el enlace.');
      return;
    }
    const { error: e } = await supabase.auth.resetPasswordForEmail(email.trim(), {
      redirectTo: `${window.location.origin}/ingresar`,
    });
    if (e) setError(mensajeError(e));
    else setAviso('Si el correo está registrado, recibirá un enlace para crear una contraseña nueva.');
  }

  return (
    <div className="login">
      <section className="login-marca">
        <img src="/brand/fidelis-fianzas.svg" alt="Fidelis Fianzas" />
        <div>
          <h1>Fianzas de consignación</h1>
          <p className="muted" style={{ marginTop: '0.75rem', maxWidth: '28rem' }}>
            Solicite altas y bajas, siga cada expediente y consulte su cuenta por cobrar en un solo lugar.
          </p>
        </div>
        <p className="small muted">Fidelis, Su mejor opción en Fianzas · 2285 7000</p>
      </section>
      <section className="login-form">
        <form onSubmit={enviar} className="stack" noValidate>
          <h2>Ingresar</h2>
          {error && <Aviso tono="critico">{error}</Aviso>}
          {aviso && <Aviso tono="ok">{aviso}</Aviso>}
          <Campo label="Correo electrónico">
            {(p) => (
              <input {...p} className="control" type="email" autoComplete="username" value={email}
                onChange={(e) => setEmail(e.target.value)} required />
            )}
          </Campo>
          <Campo label="Contraseña">
            {(p) => (
              <input {...p} className="control" type="password" autoComplete="current-password" value={password}
                onChange={(e) => setPassword(e.target.value)} required />
            )}
          </Campo>
          <button className="btn btn-primario" type="submit" disabled={enviando || !email || !password}>
            {enviando ? 'Ingresando' : 'Ingresar'}
          </button>
          <button type="button" className="btn btn-texto" onClick={recuperar}>Olvidé mi contraseña</button>
          <p className="small muted">
            Las cuentas las crea Fidelis. Si su empresa necesita acceso, escriba a su ejecutivo comercial.
          </p>
        </form>
      </section>
    </div>
  );
}
