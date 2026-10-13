import { useState } from 'react';
import { useAuth } from '../auth/AuthProvider';
import { Aviso, Campo } from '../components/ui';
import { mensajeError } from '../lib/errores';

export default function CrearClave() {
  const { usuario, cambiarClave } = useAuth();
  const [clave, setClave] = useState('');
  const [repetir, setRepetir] = useState('');
  const [error, setError] = useState('');
  const [enviando, setEnviando] = useState(false);

  async function enviar(e) {
    e.preventDefault();
    if (clave.length < 10 || !/\d/.test(clave) || !/[a-zA-Z]/.test(clave)) {
      setError('Use al menos 10 caracteres, con letras y números.');
      return;
    }
    if (clave !== repetir) {
      setError('Las contraseñas no coinciden.');
      return;
    }
    setEnviando(true);
    try {
      await cambiarClave(clave);
    } catch (err) {
      setError(mensajeError(err));
    } finally {
      setEnviando(false);
    }
  }

  return (
    <div className="publica">
      <header className="publica-cabecera">
        <img src="/brand/fidelis-fianzas.svg" alt="Fidelis Fianzas" />
      </header>
      <div className="publica-cuerpo" style={{ maxWidth: 440 }}>
        <form className="stack" onSubmit={enviar} noValidate>
          <h1 style={{ fontSize: 'var(--t-xl)' }}>Cree su contraseña</h1>
          <p className="muted">Cuenta {usuario?.email}</p>
          {error && <Aviso tono="critico">{error}</Aviso>}
          <Campo label="Contraseña nueva" ayuda="Al menos 10 caracteres, con letras y números.">
            {(p) => <input {...p} className="control" type="password" autoComplete="new-password" value={clave} onChange={(e) => setClave(e.target.value)} />}
          </Campo>
          <Campo label="Repita la contraseña">
            {(p) => <input {...p} className="control" type="password" autoComplete="new-password" value={repetir} onChange={(e) => setRepetir(e.target.value)} />}
          </Campo>
          <button className="btn btn-primario" disabled={enviando}>{enviando ? 'Guardando' : 'Guardar y continuar'}</button>
        </form>
      </div>
    </div>
  );
}
