import { useEffect, useId, useRef } from 'react';
import { Link } from 'react-router-dom';
import { AlertTriangle, CheckCircle2, Info, X, XCircle } from 'lucide-react';
import { info } from '../../domain/estados';
import { mensajeError } from '../../lib/errores';

export function Estado({ mapa, valor, texto, tono }) {
  const datos = mapa ? info(mapa, valor) : { texto, tono };
  return <span className={`estado estado-${datos.tono || 'neutro'}`}>{datos.texto}</span>;
}

export function Campo({ label, opcional, ayuda, error, children, className = '' }) {
  const id = useId();
  const hijo = typeof children === 'function'
    ? children({ id, 'aria-invalid': error ? 'true' : undefined, 'aria-describedby': error || ayuda ? `${id}-d` : undefined })
    : children;
  return (
    <div className={`campo ${className}`}>
      {label && (
        <label htmlFor={id}>
          {label} {opcional && <span className="opcional">(opcional)</span>}
        </label>
      )}
      {hijo}
      {(error || ayuda) && (
        <span id={`${id}-d`} className={error ? 'error' : 'ayuda'}>
          {error || ayuda}
        </span>
      )}
    </div>
  );
}

export function Cargando({ texto = 'Cargando' }) {
  return (
    <div className="cargando" role="status">
      <span className="spinner" aria-hidden="true" />
      {texto}
    </div>
  );
}

export function Vacio({ titulo, children, accion }) {
  return (
    <div className="vacio">
      <h3>{titulo}</h3>
      {children && <p>{children}</p>}
      {accion && <div style={{ marginTop: '1rem' }}>{accion}</div>}
    </div>
  );
}

const ICONO_AVISO = { critico: XCircle, atencion: AlertTriangle, ok: CheckCircle2, info: Info };

export function Aviso({ tono = 'info', titulo, children, accion }) {
  const Icono = ICONO_AVISO[tono] || Info;
  return (
    <div className={`aviso ${tono}`} role={tono === 'critico' ? 'alert' : 'status'}>
      <Icono size={20} aria-hidden="true" />
      <div style={{ flex: 1 }}>
        {titulo && <strong style={{ display: 'block', color: 'var(--negro)' }}>{titulo}</strong>}
        {children}
      </div>
      {accion}
    </div>
  );
}

export function ErrorCarga({ error, reintentar }) {
  return (
    <Aviso
      tono="critico"
      titulo="No se pudo cargar la información"
      accion={reintentar && <button className="btn btn-secundario btn-sm" onClick={reintentar}>Reintentar</button>}
    >
      {mensajeError(error)}
    </Aviso>
  );
}

const ENFOCABLES = 'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function Modal({ titulo, subtitulo, onCerrar, children, pie, ancho = false }) {
  const ref = useRef(null);
  const idTitulo = useId();
  const idSubtitulo = useId();
  // onCerrar suele ser una funcion nueva en cada render. Con la ref, el efecto corre una sola vez
  // al abrir y el foco no salta al primer campo cada vez que la persona escribe.
  const cerrarRef = useRef(onCerrar);
  useEffect(() => {
    cerrarRef.current = onCerrar;
  });

  useEffect(() => {
    const anterior = document.activeElement;
    const nodo = ref.current;
    nodo?.querySelector('input:not([disabled]), select:not([disabled]), textarea:not([disabled]), button:not([data-cerrar]):not([disabled])')?.focus();
    const tecla = (e) => {
      if (e.key === 'Escape') {
        cerrarRef.current?.();
        return;
      }
      if (e.key !== 'Tab' || !nodo) return;
      // Foco atrapado: Tab y Shift+Tab dan la vuelta dentro del dialogo.
      const enfocables = [...nodo.querySelectorAll(ENFOCABLES)].filter((el) => el.offsetParent !== null || el === document.activeElement);
      if (!enfocables.length) {
        e.preventDefault();
        return;
      }
      const primero = enfocables[0];
      const ultimo = enfocables[enfocables.length - 1];
      if (e.shiftKey && (document.activeElement === primero || !nodo.contains(document.activeElement))) {
        e.preventDefault();
        ultimo.focus();
      } else if (!e.shiftKey && (document.activeElement === ultimo || !nodo.contains(document.activeElement))) {
        e.preventDefault();
        primero.focus();
      }
    };
    document.addEventListener('keydown', tecla);
    document.body.style.overflow = 'hidden';
    return () => {
      document.removeEventListener('keydown', tecla);
      document.body.style.overflow = '';
      anterior?.focus?.();
    };
  }, []);

  return (
    <div className="modal-fondo" onMouseDown={(e) => e.target === e.currentTarget && onCerrar?.()}>
      <div className={`modal ${ancho ? 'ancho' : ''}`} role="dialog" aria-modal="true" aria-labelledby={idTitulo}
        aria-describedby={subtitulo ? idSubtitulo : undefined} ref={ref}>
        <div className="modal-cabecera">
          <div>
            <h2 id={idTitulo} style={{ fontSize: 'var(--t-lg)' }}>{titulo}</h2>
            {subtitulo && <p id={idSubtitulo} className="muted small" style={{ marginTop: '0.25rem' }}>{subtitulo}</p>}
          </div>
          <button className="btn btn-icono" onClick={onCerrar} aria-label="Cerrar" data-cerrar>
            <X size={20} />
          </button>
        </div>
        <div className="modal-cuerpo">{children}</div>
        {pie && <div className="modal-pie">{pie}</div>}
      </div>
    </div>
  );
}

export function Paginacion({ pagina, porPagina, total, onCambiar }) {
  const paginas = Math.max(1, Math.ceil((total || 0) / porPagina));
  if (!total) return null;
  const desde = (pagina - 1) * porPagina + 1;
  const hasta = Math.min(pagina * porPagina, total);
  return (
    <div className="paginacion">
      <span>
        {desde.toLocaleString('es-GT')} a {hasta.toLocaleString('es-GT')} de {total.toLocaleString('es-GT')}
      </span>
      <div className="row">
        <button className="btn btn-secundario btn-sm" disabled={pagina <= 1} onClick={() => onCambiar(pagina - 1)}>
          Anterior
        </button>
        <button className="btn btn-secundario btn-sm" disabled={pagina >= paginas} onClick={() => onCambiar(pagina + 1)}>
          Siguiente
        </button>
      </div>
    </div>
  );
}

export function Pestanas({ opciones, valor, onCambiar }) {
  return (
    <div className="pestanas" role="tablist">
      {opciones.map((o) => (
        <button
          key={o.valor}
          role="tab"
          className="pestana"
          aria-selected={valor === o.valor}
          onClick={() => onCambiar(o.valor)}
        >
          {o.texto}
          {o.contador !== undefined && o.contador !== null && (
            <span className="muted" style={{ marginLeft: '0.4rem', fontWeight: 400 }}>{o.contador}</span>
          )}
        </button>
      ))}
    </div>
  );
}

export function Kpi({ pregunta, valor, contexto, destacado, fuente, to, icono: Icono }) {
  const contenido = (
    <>
      <div className="kpi-cabeza">
        <div className="pregunta">{pregunta}</div>
        {Icono && <span className="kpi-icono" aria-hidden="true"><Icono size={18} /></span>}
      </div>
      <div className="valor">{valor}</div>
      {contexto && <div className="contexto">{contexto}</div>}
    </>
  );
  return (
    <div className={`kpi ${destacado ? 'destacado' : ''}`} title={fuente ? `Fuente: ${fuente}` : undefined}>
      {to ? <Link to={to}>{contenido}</Link> : contenido}
    </div>
  );
}

export function Datos({ items }) {
  return (
    <dl className="datos">
      {items.filter(Boolean).map(([etiqueta, valor]) => (
        <div key={etiqueta}>
          <dt>{etiqueta}</dt>
          <dd>{valor === null || valor === undefined || valor === '' ? <span className="muted">Sin dato</span> : valor}</dd>
        </div>
      ))}
    </dl>
  );
}

export function Panel({ titulo, subtitulo, accion, pie, children, sinRelleno = false }) {
  return (
    <section className="panel">
      {(titulo || accion) && (
        <div className="panel-cabeza">
          <div>
            {titulo && <h2>{titulo}</h2>}
            {subtitulo && <span className="sub">{subtitulo}</span>}
          </div>
          {accion}
        </div>
      )}
      {sinRelleno ? children : <div className="panel-cuerpo">{children}</div>}
      {pie && <div className="panel-pie">{pie}</div>}
    </section>
  );
}

export function Encabezado({ titulo, descripcion, acciones, volver }) {
  return (
    <>
      {volver}
      <div className="encabezado">
        <div>
          <h1>{titulo}</h1>
          {descripcion && <p>{descripcion}</p>}
        </div>
        {acciones && <div className="row">{acciones}</div>}
      </div>
    </>
  );
}
