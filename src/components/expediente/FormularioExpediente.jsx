import { useEffect, useId, useMemo, useRef, useState } from 'react';
import { Camera, CheckCircle2, Circle, FileUp, Trash2 } from 'lucide-react';
import { Aviso, Campo, Estado } from '../ui';
import {
  VERSION_DECLARACION, camposVisibles, datosIniciales, derivar, etiquetaCampo, pendientesPorSeccion, seccionesPara, validarFormulario,
} from '../../domain/formularioIve';
import { fecha } from '../../lib/format';
import { mensajeError } from '../../lib/errores';

// Expediente compartido: lo usan el distribuidor (portal con enlace) y la marca (su portal).
// Se puede saltar a cualquier parte sin terminar la anterior. Solo el envio final exige todo.
// Cada guardado manda solo lo que cambio, para que marca y distribuidor no se pisen.
// Con enviado, la marca corrige el formulario que el distribuidor ya envio: no puede dejarlo
// incompleto, asi que un cambio con error no se guarda y queda en pantalla para corregirlo.

const AUTOCOMPLETAR = {
  primerNombre: 'given-name', segundoNombre: 'additional-name', primerApellido: 'family-name',
  telefono: 'tel', correo: 'email', direccion: 'street-address',
  telefonoEmpresa: 'tel', correoEmpresa: 'email', direccionSede: 'street-address', razonSocial: 'organization',
};

const MIME_ACEPTADOS = ['application/pdf', 'image/png', 'image/jpeg'];

// Las fotos del telefono pesan 4 a 8 MB. Se reducen antes de subir para conexiones lentas.
async function prepararArchivo(archivo) {
  if (!archivo.type.startsWith('image/') || archivo.size < 2_500_000) return archivo;
  try {
    const imagen = await createImageBitmap(archivo);
    const escala = Math.min(1, 2200 / Math.max(imagen.width, imagen.height));
    const lienzo = document.createElement('canvas');
    lienzo.width = Math.round(imagen.width * escala);
    lienzo.height = Math.round(imagen.height * escala);
    lienzo.getContext('2d').drawImage(imagen, 0, 0, lienzo.width, lienzo.height);
    const blob = await new Promise((ok) => lienzo.toBlob(ok, 'image/jpeg', 0.85));
    return blob ? new File([blob], archivo.name.replace(/\.\w+$/, '') + '.jpg', { type: 'image/jpeg' }) : archivo;
  } catch {
    return archivo;
  }
}

function CampoFilas({ campo, valor, onCambiar }) {
  const filas = Array.isArray(valor) ? valor : [];
  const vacia = Object.fromEntries(campo.columnas.map((c) => [c.id, '']));
  const cambiarFila = (i, id, v) => onCambiar(filas.map((f, j) => (j === i ? { ...f, [id]: v } : f)));
  return (
    <div className="completo stack">
      {filas.map((fila, i) => (
        <fieldset key={i} className="bloque-filas">
          <legend className="small">Punto de venta {i + 1}</legend>
          <div className="grid-2">
            {campo.columnas.map((c) => (
              <CampoFormulario key={c.id} campo={c} valor={fila[c.id]} onCambiar={(v) => cambiarFila(i, c.id, v)} />
            ))}
          </div>
          <button type="button" className="btn btn-texto btn-sm" onClick={() => onCambiar(filas.filter((_, j) => j !== i))}>Quitar</button>
        </fieldset>
      ))}
      <div>
        <button type="button" className="btn btn-secundario btn-sm" onClick={() => onCambiar([...filas, vacia])}>Agregar punto de venta</button>
      </div>
    </div>
  );
}

// Pregunta de Si o No: un grupo con su leyenda, para que el lector de pantalla lea la pregunta
// junto a cada opcion y anuncie el error.
function CampoSiNo({ campo, valor, error, onCambiar }) {
  const id = useId();
  const nota = error || campo.ayuda;
  return (
    <fieldset className="campo completo campo-grupo" aria-invalid={error ? 'true' : undefined}
      aria-describedby={nota ? `${id}-d` : undefined}>
      <legend>{campo.label} {!campo.requerido && <span className="opcional">(opcional)</span>}</legend>
      <div className="opciones">
        {campo.opciones.map((o) => (
          <label key={o.valor} className="opcion">
            <input type="radio" name={campo.id} value={o.valor} checked={valor === o.valor} onChange={() => onCambiar(o.valor)} />
            {o.texto}
          </label>
        ))}
      </div>
      {nota && <span id={`${id}-d`} className={error ? 'error' : 'ayuda'}>{nota}</span>}
    </fieldset>
  );
}

function CampoFormulario({ campo, valor, error, onCambiar, onTocar }) {
  if (campo.tipo === 'filas') return <CampoFilas campo={campo} valor={valor} onCambiar={onCambiar} />;
  if (campo.tipo === 'sino') return <CampoSiNo campo={campo} valor={valor} error={error} onCambiar={onCambiar} />;
  const comun = (p) => ({ ...p, className: 'control', value: valor ?? '', onChange: (e) => onCambiar(e.target.value), onBlur: onTocar });
  return (
    <Campo label={campo.label} opcional={!campo.requerido} ayuda={campo.ayuda} error={error}
      className={campo.ancho === 'completo' ? 'completo' : ''}>
      {(p) => {
        if (campo.tipo === 'select') {
          return (
            <select {...comun(p)}>
              <option value="">Elija</option>
              {campo.opciones.map((o) => <option key={o.valor} value={o.valor}>{o.texto}</option>)}
            </select>
          );
        }
        if (campo.tipo === 'textarea') return <textarea {...comun(p)} />;
        return (
          <input {...comun(p)} type={campo.tipo === 'number' ? 'text' : campo.tipo}
            inputMode={campo.tipo === 'number' ? 'decimal' : campo.inputMode}
            autoComplete={AUTOCOMPLETAR[campo.id] || 'off'} />
        );
      }}
    </Campo>
  );
}

const vigentes = (r) => r.documentos.filter((d) => d.estado !== 'RECHAZADO');

function faltanDocumentos(requisitos, modo) {
  return (requisitos || []).filter((r) => r.obligatorio && !vigentes(r).length
    && (modo !== 'afianzado' || r.responsable !== 'MARCA'));
}

export function Documentos({ requisitos, faltantesPedidos, modo, subir, quitar, onCambio }) {
  const [errores, setErrores] = useState({});
  const [subiendo, setSubiendo] = useState('');
  const prefijo = useId();
  const tactil = typeof window !== 'undefined' && window.matchMedia?.('(pointer: coarse)').matches;

  async function cargar(categoria, original) {
    setErrores((e) => ({ ...e, [categoria]: '' }));
    const archivo = await prepararArchivo(original);
    if (!MIME_ACEPTADOS.includes(archivo.type)) {
      setErrores((e) => ({ ...e, [categoria]: 'Solo PDF o fotos (JPG o PNG).' }));
      return;
    }
    if (archivo.size > 15 * 1024 * 1024) {
      setErrores((e) => ({ ...e, [categoria]: 'El archivo debe pesar menos de 15 MB.' }));
      return;
    }
    setSubiendo(categoria);
    try {
      await subir({ archivo, categoria });
      onCambio?.();
    } catch (e) {
      setErrores((x) => ({ ...x, [categoria]: mensajeError(e) }));
    } finally {
      setSubiendo('');
    }
  }

  const idError = (r) => `${prefijo}-${r.categoria}-error`;
  const entrada = (r, propias) => (
    <input type="file" className="sr-only" disabled={Boolean(subiendo)} {...propias}
      aria-invalid={errores[r.categoria] ? 'true' : undefined}
      aria-describedby={errores[r.categoria] ? idError(r) : undefined}
      onChange={(e) => {
        const archivo = e.target.files?.[0];
        e.target.value = '';
        if (archivo) cargar(r.categoria, archivo);
      }} />
  );

  return (
    <ul className="doc-lista">
      {requisitos.map((r) => {
        const pedido = (faltantesPedidos || []).includes(r.categoria);
        const deLaMarca = r.responsable === 'MARCA';
        return (
          <li key={r.categoria} className="doc">
            <div>
              <span className="doc-titulo">
                {vigentes(r).length
                  ? <CheckCircle2 size={16} aria-hidden="true" style={{ color: 'var(--ok)', verticalAlign: '-3px', marginRight: 6 }} />
                  : <Circle size={16} aria-hidden="true" style={{ color: 'var(--gris-500)', verticalAlign: '-3px', marginRight: 6 }} />}
                {r.nombre}
              </span>
              {!r.obligatorio && <span className="muted small"> (si aplica)</span>}
              {r.ayuda && <span className="sub">{r.ayuda}</span>}
              {deLaMarca && modo === 'afianzado' && <span className="sub">Lo envía su marca. Si usted lo tiene, también puede subirlo.</span>}
              {deLaMarca && modo === 'marca' && !vigentes(r).length && <span className="sub" style={{ color: 'var(--atencion)' }}>Le toca a usted.</span>}
              {pedido && <span className="sub" style={{ color: 'var(--atencion)' }}>Falta este documento.</span>}
            </div>
            <div className="row" style={{ gap: '0.4rem', justifyContent: 'flex-end' }}>
              {tactil && (
                <label className="btn btn-primario btn-sm" style={{ cursor: 'pointer' }}>
                  <Camera size={16} aria-hidden="true" /> {subiendo === r.categoria ? 'Subiendo' : 'Tomar foto'}
                  {entrada(r, { accept: 'image/*', capture: 'environment' })}
                </label>
              )}
              <label className="btn btn-secundario btn-sm" style={{ cursor: 'pointer' }}>
                <FileUp size={16} aria-hidden="true" />
                {subiendo === r.categoria && !tactil ? 'Subiendo' : vigentes(r).length ? 'Agregar otro' : 'Subir archivo'}
                {entrada(r, { accept: 'application/pdf,image/png,image/jpeg,image/*' })}
              </label>
            </div>
            {(r.documentos.length > 0 || errores[r.categoria]) && (
              <div className="doc-archivos">
                {vigentes(r).map((d) => (
                  <div key={d.id} className="archivo">
                    <span className="nombre">{d.nombre_archivo}</span>
                    <span className="small muted">{d.origen === 'MARCA' ? 'subido por la marca' : d.origen === 'FIDELIS' ? 'subido por Fidelis' : 'subido por el distribuidor'}</span>
                    <Estado texto="Recibido" tono="ok" />
                    {d.estado === 'PENDIENTE' && quitar && (
                      <button className="btn btn-texto btn-sm" onClick={() => quitar(d.id).then(onCambio).catch((e) => setErrores((x) => ({ ...x, [r.categoria]: mensajeError(e) })))}
                        aria-label={`Quitar ${d.nombre_archivo}`}>
                        <Trash2 size={14} aria-hidden="true" /> Quitar
                      </button>
                    )}
                  </div>
                ))}
                {errores[r.categoria] && <span id={idError(r)} role="alert" className="small" style={{ color: 'var(--critico)' }}>{errores[r.categoria]}</span>}
              </div>
            )}
          </li>
        );
      })}
    </ul>
  );
}

// Enlace de una solicitud ya enviada: el IVE no cambia, solo se suben los documentos que faltan.
// No hay formulario ni guardado automatico. El envio no lleva datos: el servidor los ignora.
export function EnvioDeDocumentos({ requisitos, faltantesPedidos, subir, quitar, enviar, onCambioDocumentos }) {
  const propios = (requisitos || []).filter((r) => r.responsable !== 'MARCA');
  // Lo pendiente al abrir el enlace se queda en la lista aunque ya se haya subido, para ver que quedo listo.
  const [pedidas] = useState(() => new Set(propios
    .filter((r) => (faltantesPedidos || []).includes(r.categoria)
      || (r.obligatorio && !vigentes(r).length))
    .map((r) => r.categoria)));
  const lista = pedidas.size ? propios.filter((r) => pedidas.has(r.categoria)) : propios;
  const faltan = faltanDocumentos(lista, 'afianzado');
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState('');

  async function enviarDocumentos() {
    setError('');
    setEnviando(true);
    try {
      await enviar({});
    } catch (e) {
      setError(mensajeError(e));
    } finally {
      setEnviando(false);
    }
  }

  return (
    <section className="stack-lg">
      <p className="muted">
        {pedidas.size
          ? `Suba ${pedidas.size === 1 ? 'el documento que falta' : `los ${pedidas.size} documentos que faltan`}. Puede tomar una foto con el teléfono o subir un PDF.`
          : 'No hay documentos pendientes. Si tiene otro que corresponda, súbalo aquí.'}
      </p>
      <Documentos requisitos={lista} faltantesPedidos={faltantesPedidos} modo="afianzado" subir={subir} quitar={quitar} onCambio={onCambioDocumentos} />
      {faltan.length > 0 && (
        <Aviso tono="atencion" titulo={`Lo que falta (${faltan.length})`}>
          {faltan.map((r) => r.nombre).join(', ')}. Puede enviar lo que ya subió y completar el resto con un enlace nuevo.
        </Aviso>
      )}
      {error && <Aviso tono="critico">{error}</Aviso>}
      <div>
        <button className="btn btn-primario" onClick={enviarDocumentos} disabled={enviando}>
          {enviando ? 'Enviando' : 'Enviar documentos'}
        </button>
      </div>
    </section>
  );
}

// El servidor rechaza un formulario enviado que queda sin un dato obligatorio.
function campoRechazado(error) {
  return /Falta el campo IVE requerido: (\w+)/.exec(error?.message || '')?.[1] || null;
}

export default function FormularioExpediente({
  tipoPersona, borrador, requisitos, faltantesPedidos, modo, enviado = false, guardar, subir, quitar, enviar, onCambioDocumentos, aviso,
}) {
  const secciones = useMemo(() => seccionesPara(tipoPersona), [tipoPersona]);
  const [datos, setDatos] = useState(() => datosIniciales(tipoPersona, borrador || {}));
  const [paso, setPaso] = useState(0);
  const [intentoEnvio, setIntentoEnvio] = useState(false);
  // Campos que la persona ya dejo: muestran su error de formato sin esperar al envio.
  const [tocados, setTocados] = useState(() => new Set());
  const [estadoGuardado, setEstadoGuardado] = useState('');
  const [errorGuardado, setErrorGuardado] = useState('');
  // Errores que devolvio el servidor al guardar, por campo. Se borran al cambiar ese campo.
  const [erroresServidor, setErroresServidor] = useState({});
  const [errorEnvio, setErrorEnvio] = useState('');
  const [enviando, setEnviando] = useState(false);
  const idForm = useId();
  const guardado = useRef(derivar(tipoPersona, datosIniciales(tipoPersona, borrador || {})));

  const pasoDocs = secciones.length;
  const pasoFinal = secciones.length + 1;
  const pendientes = pendientesPorSeccion(tipoPersona, datos);
  const docsFaltan = faltanDocumentos(requisitos, modo);
  const docsListos = (requisitos || []).filter((r) => vigentes(r).length).length;
  const totalPendientes = pendientes.reduce((t, p) => t + p.faltan.length, 0);

  // Guardado automatico de lo que cambio, 1.5 s despues de dejar de escribir.
  useEffect(() => {
    const t = setTimeout(async () => {
      const actual = derivar(tipoPersona, datos);
      const cambios = Object.fromEntries(Object.entries(actual)
        .filter(([k, v]) => JSON.stringify(v) !== JSON.stringify(guardado.current[k]))
        .filter(([k]) => k !== 'declaracionVeracidad'));
      if (!Object.keys(cambios).length) return;
      // Formulario enviado: lo que tiene error se queda en pantalla y se guarda lo demas.
      const conError = enviado
        ? Object.keys(validarFormulario(tipoPersona, datos)).filter((k) => k !== 'declaracionVeracidad' && k in cambios)
        : [];
      const porGuardar = Object.fromEntries(Object.entries(cambios).filter(([k]) => !conError.includes(k)));
      if (conError.length) setTocados((x) => new Set([...x, ...conError]));
      if (!Object.keys(porGuardar).length) {
        setEstadoGuardado('Sin guardar. Corrija los datos marcados.');
        return;
      }
      try {
        setEstadoGuardado('Guardando');
        setErrorGuardado('');
        await guardar(porGuardar);
        guardado.current = { ...guardado.current, ...porGuardar };
        const hora = new Date().toLocaleTimeString('es-GT', { hour: '2-digit', minute: '2-digit' });
        setEstadoGuardado(conError.length ? `Guardado lo demás a las ${hora}. Corrija los datos marcados.` : `Guardado a las ${hora}`);
      } catch (e) {
        const campo = campoRechazado(e);
        if (campo) {
          setErroresServidor((x) => ({ ...x, [campo]: 'Este dato es obligatorio. El formulario ya se envió y no puede quedar sin él.' }));
          setTocados((x) => new Set(x).add(campo));
          setErrorGuardado(`No se guardó: ${etiquetaCampo(campo).replace(/^¿/, '').replace(/\?$/, '')} es obligatorio en un formulario ya enviado. Lo que escribió sigue en esta pantalla.`);
        } else {
          setErrorGuardado(`No se guardó. ${mensajeError(e)} Lo que escribió sigue en esta pantalla.`);
        }
        setEstadoGuardado('Sin guardar');
      }
    }, 1500);
    return () => clearTimeout(t);
  }, [datos, tipoPersona, guardar, enviado]);

  const cambiar = (id) => (valor) => {
    setDatos((d) => ({ ...d, [id]: valor }));
    setErroresServidor((x) => {
      if (!(id in x)) return x;
      const resto = { ...x };
      delete resto[id];
      return resto;
    });
  };
  const tocar = (id) => () => setTocados((t) => (t.has(id) ? t : new Set(t).add(id)));
  const ir = (n) => {
    setPaso(n);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };
  const todosLosErrores = validarFormulario(tipoPersona, datos);
  const errores = {
    ...(intentoEnvio
      ? todosLosErrores
      // Antes de intentar enviar: solo el error de formato de lo que ya se escribio y se dejo.
      // En un formulario enviado tambien el de un obligatorio que se vacio.
      : Object.fromEntries(Object.entries(todosLosErrores)
        .filter(([id]) => tocados.has(id) && (enviado || String(datos[id] ?? '').trim() !== '')))),
    ...erroresServidor,
  };

  async function enviarTodo() {
    setErrorEnvio('');
    setIntentoEnvio(true);
    if (Object.keys(todosLosErrores).length) return;
    setEnviando(true);
    try {
      await enviar({ ...derivar(tipoPersona, datos), versionDeclaracion: VERSION_DECLARACION });
    } catch (e) {
      setErrorEnvio(mensajeError(e));
    } finally {
      setEnviando(false);
    }
  }

  const pasos = [
    ...secciones.map((s, i) => ({ texto: s.titulo, listo: pendientes[i].faltan.length === 0, n: pendientes[i].faltan.length })),
    { texto: 'Documentos', listo: docsFaltan.length === 0, n: docsFaltan.length },
    ...(modo === 'afianzado' ? [{ texto: 'Revisar y enviar', listo: false, n: 0 }] : [{ texto: 'Avance', listo: false, n: 0 }]),
  ];

  return (
    <div>
      <nav className="expediente-pasos" aria-label="Partes del expediente">
        {pasos.map((p, i) => (
          <button key={p.texto} type="button" className={`expediente-paso ${i === paso ? 'actual' : ''} ${p.listo ? 'listo' : ''}`}
            aria-current={i === paso ? 'step' : undefined} onClick={() => ir(i)}>
            <span className="expediente-paso-marca" aria-hidden="true">{p.listo ? <CheckCircle2 size={16} /> : i + 1}</span>
            <span>{p.texto}</span>
            {!p.listo && p.n > 0 && <span className="expediente-paso-n">{p.n}</span>}
          </button>
        ))}
      </nav>

      {aviso}

      {paso < pasoDocs && (
        <section className="bloque-form">
          <h3>{secciones[paso].titulo}</h3>
          {secciones[paso].descripcion && <p className="small muted" style={{ marginBottom: '1rem' }}>{secciones[paso].descripcion}</p>}
          <div className="grid-2">
            {camposVisibles(secciones[paso], datos).map((c) => (
              <CampoFormulario key={c.id} campo={c} valor={datos[c.id]} error={errores[c.id]} onCambiar={cambiar(c.id)} onTocar={tocar(c.id)} />
            ))}
          </div>
        </section>
      )}

      {paso === pasoDocs && (
        <section className="stack-lg">
          <p className="muted">
            Puede tomar una foto con el teléfono o subir un PDF. {docsListos} de {requisitos.length} listos.
            {modo === 'afianzado' ? ' Si ahora no tiene alguno, siga con lo demás y vuelva con el mismo enlace.' : ''}
          </p>
          <Documentos requisitos={requisitos} faltantesPedidos={faltantesPedidos} modo={modo} subir={subir} quitar={quitar} onCambio={onCambioDocumentos} />
        </section>
      )}

      {paso === pasoFinal && (
        <section className="stack-lg">
          {totalPendientes > 0 ? (
            <div className="stack">
              <h3>Lo que falta ({totalPendientes})</h3>
              <ul className="pendientes-lista">
                {pendientes.filter((p) => p.faltan.length).map((p) => (
                  <li key={p.titulo}>
                    <div>
                      <strong>{p.titulo}</strong>
                      <ul className="pendientes-campos">
                        {p.faltan.map((x) => (
                          <li key={x.id}>{x.label.replace(/^¿/, '').replace(/\?$/, '')}: {x.error}</li>
                        ))}
                      </ul>
                    </div>
                    <button className="btn btn-secundario btn-sm" onClick={() => { setIntentoEnvio(true); ir(p.indice); }}>Completar</button>
                  </li>
                ))}
              </ul>
            </div>
          ) : (
            <Aviso tono="ok" titulo="Los datos están completos">
              {modo === 'afianzado'
                ? 'Acepte la declaración y envíe su solicitud a Fidelis.'
                : enviado ? 'El distribuidor ya envió. Fidelis ve sus correcciones en el expediente.' : 'Falta que el distribuidor revise y envíe desde su enlace.'}
            </Aviso>
          )}
          {docsFaltan.length > 0 && (
            <Aviso tono="atencion" titulo={`Quedan ${docsFaltan.length} documento${docsFaltan.length > 1 ? 's' : ''} pendiente${docsFaltan.length > 1 ? 's' : ''}`}
              accion={<button className="btn btn-secundario btn-sm" onClick={() => ir(pasoDocs)}>Subir</button>}>
              {docsFaltan.map((r) => r.nombre).join(', ')}.
              {modo === 'afianzado'
                ? ' Puede enviar ahora. Después, su marca le envía un enlace para subir lo que falte.'
                : enviado ? ' Puede subirlos usted o generar un enlace para que el distribuidor los suba.' : ' El distribuidor puede enviar igual y subirlos después.'}
            </Aviso>
          )}
          {modo === 'marca' && !enviado && totalPendientes > 0 && (
            <p className="small muted">El distribuidor ve lo mismo en su enlace. Al final él revisa y envía.</p>
          )}
          {modo === 'afianzado' && (
            <>
              <section className="stack">
                <h3>Declaración de veracidad</h3>
                <label className="check">
                  <input type="checkbox" checked={Boolean(datos.declaracionVeracidad)} onChange={(e) => cambiar('declaracionVeracidad')(e.target.checked)}
                    aria-invalid={errores.declaracionVeracidad ? 'true' : undefined}
                    aria-describedby={errores.declaracionVeracidad ? `${idForm}-declaracion` : undefined} />
                  <span>
                    Declaro que la información de este formulario y los documentos que adjunto son verídicos, y autorizo a Fidelis a
                    verificarlos y a consultar referencias, conforme a la legislación contra el lavado de dinero. Fecha: {fecha(new Date())}.
                  </span>
                </label>
                {errores.declaracionVeracidad && <span id={`${idForm}-declaracion`} className="small" style={{ color: 'var(--critico)' }}>{errores.declaracionVeracidad}</span>}
              </section>
              {errorEnvio && <Aviso tono="critico">{errorEnvio}</Aviso>}
              <button className="btn btn-primario" onClick={enviarTodo}
                disabled={enviando || totalPendientes > 0}>
                {enviando ? 'Enviando' : 'Enviar a Fidelis'}
              </button>
              {totalPendientes > 0 && <p className="small muted">Para enviar, complete lo que falta de la lista.</p>}
            </>
          )}
        </section>
      )}

      {errorGuardado && <div style={{ marginTop: '1rem' }}><Aviso tono="critico">{errorGuardado}</Aviso></div>}

      <div className="acciones" style={{ justifyContent: 'space-between' }}>
        {paso > 0 ? <button className="btn btn-secundario" onClick={() => ir(paso - 1)}>Atrás</button> : <span />}
        <span className="small muted" role="status" aria-live="polite">{estadoGuardado}</span>
        {paso < pasoFinal && (
          <button className="btn btn-primario" onClick={() => ir(paso + 1)}>
            {paso === pasoDocs - 1 ? 'Ir a documentos' : paso === pasoDocs ? (modo === 'afianzado' ? 'Revisar y enviar' : 'Ver avance') : 'Siguiente'}
          </button>
        )}
      </div>
    </div>
  );
}
