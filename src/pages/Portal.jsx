import { useCallback, useState } from 'react';
import { Lock } from 'lucide-react';
import { Aviso, Cargando } from '../components/ui';
import FormularioExpediente, { EnvioDeDocumentos } from '../components/expediente/FormularioExpediente';
import {
  guardarBorrador, useContextoPortal, useEnviarExpediente, useQuitarDocumentoPortal, useSubirDocumentoPortal,
} from '../data/portal';
import { fechaHora, nombre, q } from '../lib/format';
import { mensajeError } from '../lib/errores';

const MOTIVOS = {
  NO_EXISTE: 'El enlace no es válido. Revise que lo haya copiado completo.',
  ENVIADO: 'Su solicitud ya fue enviada. Si falta algo, su marca le envía un enlace nuevo.',
  REEMPLAZADO: 'Este enlace fue reemplazado por uno más reciente. Use el último que recibió.',
  EXPIRADO: 'Este enlace venció. Pida uno nuevo a su marca.',
  CERRADO: 'Su solicitud ya no admite cambios.',
};

// El token es la llave del expediente: no debe quedar en el historial, en marcadores ni en el
// Referer. Se lee una vez de ?t=, se guarda en la pestana y se quita de la barra de direcciones.
const CLAVE_TOKEN = 'd6-portal-token';
let tokenEnMemoria = '';

function tomarToken() {
  const url = new URL(window.location.href);
  const enUrl = url.searchParams.get('t');
  if (enUrl) {
    tokenEnMemoria = enUrl;
    try {
      sessionStorage.setItem(CLAVE_TOKEN, enUrl);
    } catch {
      // Sin almacenamiento el enlace dura mientras la pagina siga abierta.
    }
    url.searchParams.delete('t');
    window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
    return enUrl;
  }
  if (tokenEnMemoria) return tokenEnMemoria;
  try {
    return sessionStorage.getItem(CLAVE_TOKEN) || '';
  } catch {
    return '';
  }
}

const TELEFONO = <a href="tel:+50222857000">2285 7000</a>;

function Cabecera() {
  return (
    <header className="publica-cabecera">
      <img src="/brand/fidelis-fianzas.svg" alt="Fidelis Fianzas" />
      <span className="small muted row" style={{ gap: '0.35rem' }}>
        <Lock size={14} aria-hidden="true" /> Enlace personal
      </span>
    </header>
  );
}

function Bienvenida({ ctx }) {
  const docs = ctx.requisitos.filter((r) => r.responsable !== 'MARCA');
  if (ctx.solo_documentos) {
    return (
      <div className="stack" style={{ marginBottom: '1.5rem' }}>
        <h1 style={{ fontSize: 'var(--t-xl)' }}>Documentos para su fianza con {nombre(ctx.marca)}</h1>
        <p>
          Fidelis ya recibió sus datos. Con este enlace solo sube los documentos que faltan y los envía.
          Puede volver con el mismo enlace hasta el {fechaHora(ctx.expira)}.
        </p>
      </div>
    );
  }
  return (
    <div className="stack" style={{ marginBottom: '1.5rem' }}>
      <h1 style={{ fontSize: 'var(--t-xl)' }}>Su fianza con {nombre(ctx.marca)}</h1>
      <p>
        Para que {nombre(ctx.marca)} le entregue mercadería en consignación por {q(ctx.monto_solicitado)}, Fidelis necesita
        conocerlo. Son 5 partes cortas y sus documentos.
      </p>
      <details className="bienvenida-docs">
        <summary>Documentos que necesita tener a mano ({docs.filter((r) => r.obligatorio).length})</summary>
        <ul>
          {docs.map((r) => <li key={r.categoria}>{r.nombre}{!r.obligatorio && ' (si aplica)'}</li>)}
        </ul>
      </details>
      <p className="small muted">
        Puede avanzar por partes y en el orden que quiera. Lo que llena se guarda solo y puede volver con este mismo enlace
        hasta el {fechaHora(ctx.expira)}.
      </p>
      {ctx.precargado && (
        <Aviso tono="info" titulo="Le precargamos sus datos">Usamos lo que llenó la vez anterior. Revise que todo siga igual.</Aviso>
      )}
    </div>
  );
}

export default function Portal() {
  const [token] = useState(tomarToken);
  const { data: ctx, isLoading, error, refetch } = useContextoPortal(token);
  const enviar = useEnviarExpediente(token);
  const subir = useSubirDocumentoPortal(token);
  const quitar = useQuitarDocumentoPortal(token);
  const [enviado, setEnviado] = useState(null);
  const pendientesDe = (requisitos) => requisitos
    .filter((r) => r.obligatorio && r.responsable !== 'MARCA' && !r.documentos.some((d) => d.estado !== 'RECHAZADO'))
    .map((r) => r.nombre);
  const guardar = useCallback((cambios) => guardarBorrador(token, cambios), [token]);

  if (!token) {
    return <div className="publica"><Cabecera /><div className="publica-cuerpo"><Aviso tono="critico">{MOTIVOS.NO_EXISTE}</Aviso></div></div>;
  }
  if (isLoading) return <div className="publica"><Cabecera /><Cargando texto="Abriendo su solicitud" /></div>;
  if (error) {
    return (
      <div className="publica"><Cabecera /><div className="publica-cuerpo">
        <Aviso tono="critico" titulo="No se pudo abrir su solicitud" accion={<button className="btn btn-secundario btn-sm" onClick={() => refetch()}>Reintentar</button>}>
          {mensajeError(error)}
        </Aviso>
      </div></div>
    );
  }
  if (enviado || !ctx.valido) {
    return (
      <div className="publica"><Cabecera /><div className="publica-cuerpo stack">
        {enviado ? (
          <>
            <h1>{enviado.soloDocumentos ? 'Documentos enviados' : 'Solicitud enviada'}</h1>
            <Aviso tono="ok" titulo={enviado.soloDocumentos ? 'Gracias. Fidelis recibió sus documentos.' : 'Gracias. Fidelis recibió su información.'}>
              Su solicitud queda en Fidelis con sus documentos. Si falta algo, su marca le escribe. Cuando se apruebe, su marca le
              indica cómo firmar el contrato. Su número de solicitud es {ctx.numero_solicitud}.
            </Aviso>
            {enviado.pendientes.length > 0 && (
              <Aviso tono="atencion" titulo="Quedaron documentos pendientes">
                {enviado.pendientes.join(', ')}. Su marca le envía un enlace para subir lo que falte.
              </Aviso>
            )}
          </>
        ) : <Aviso tono={ctx.motivo === 'ENVIADO' ? 'ok' : 'atencion'}>{MOTIVOS[ctx.motivo] || MOTIVOS.NO_EXISTE}</Aviso>}
        <p className="small muted">¿Dudas? Llame a Fidelis al {TELEFONO}.</p>
      </div></div>
    );
  }

  return (
    <div className="publica">
      <Cabecera />
      <div className="publica-cuerpo">
        <Bienvenida ctx={ctx} />
        {ctx.solo_documentos ? (
          <EnvioDeDocumentos
            requisitos={ctx.requisitos}
            faltantesPedidos={ctx.faltantes}
            subir={(x) => subir.mutateAsync(x)}
            quitar={(id) => quitar.mutateAsync(id)}
            enviar={async () => {
              // Ya enviado: el servidor ignora los datos y solo registra los documentos.
              await enviar.mutateAsync({});
              setEnviado({ soloDocumentos: true, pendientes: pendientesDe(ctx.requisitos) });
              window.scrollTo({ top: 0 });
            }}
          />
        ) : (
          <FormularioExpediente
            tipoPersona={ctx.tipo_persona}
            borrador={ctx.borrador}
            requisitos={ctx.requisitos}
            faltantesPedidos={ctx.faltantes}
            modo="afianzado"
            guardar={guardar}
            subir={(x) => subir.mutateAsync(x)}
            quitar={(id) => quitar.mutateAsync(id)}
            enviar={async (datos) => {
              await enviar.mutateAsync(datos);
              setEnviado({ pendientes: pendientesDe(ctx.requisitos) });
              window.scrollTo({ top: 0 });
            }}
          />
        )}
        <p className="small muted" style={{ marginTop: '3rem' }}>
          Sus datos se usan solo para evaluar y emitir su fianza. ¿Dudas? Llame a Fidelis al {TELEFONO}.
        </p>
      </div>
    </div>
  );
}
