import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Download, ExternalLink, Link2 } from 'lucide-react';
import { useAuth } from '../auth/AuthProvider';
import {
  Aviso, Campo, Cargando, Datos, Encabezado, ErrorCarga, Estado, Modal, Pestanas, Vacio,
} from '../components/ui';
import { useToast } from '../components/ui/Toasts';
import EnlacePortal from '../components/EnlacePortal';
import AvanceExpediente from '../components/expediente/AvanceExpediente';
import ReferenciaDistribuidor from '../components/ReferenciaDistribuidor';
import {
  abrirDocumento, descargarDocumentos, useAltaMarca, useCambiosAlta, useExpediente, useReenviarEnlace,
} from '../data/altas';
import {
  CATEGORIA_DOCUMENTO, ESTADO_ALTA, ESTADOS_EN_TRAMITE, PASOS_ALTA, SIGUIENTE_PASO_MARCA, TIPO_PERSONA,
} from '../domain/estados';
import { alertasExpediente, revisarConsistencia } from '../domain/consistencia';
import { camposVisibles, definicionCampo, etiquetaCampo, seccionesPara, textoValor } from '../domain/formularioIve';
import { fecha, fechaHora, nombre, q, tamanoArchivo } from '../lib/format';
import { mensajeError } from '../lib/errores';
import { validateEmail, validatePhone } from '../domain/validators';

// Lista de documentos que faltan: la calcula la base con cada documento que llega.
function categoriasFaltantes(faltantes) {
  return (Array.isArray(faltantes) ? faltantes : []).map((f) => (typeof f === 'string' ? f : f?.categoria)).filter(Boolean);
}

// ---------------------------------------------------------------------------
// Linea de tiempo: el distribuidor llena, Fidelis recibe, FISO emite.
// ---------------------------------------------------------------------------
function LineaDeTiempo({ estado }) {
  const indice = estado === 'EMITIDA' ? PASOS_ALTA.length : estado === 'EXPEDIENTE_RECIBIDO' ? 1 : 0;
  if (!ESTADOS_EN_TRAMITE.includes(estado) && estado !== 'EMITIDA') return null;
  return (
    <ol className="pasos" aria-label="Avance de la solicitud">
      {PASOS_ALTA.map((p, i) => (
        <li key={p.clave} className={i < indice ? 'hecho' : i === indice ? 'actual' : ''}
          aria-current={i === indice ? 'step' : undefined}>
          {p.texto}
        </li>
      ))}
    </ol>
  );
}

function EstadoAnterior({ estado }) {
  if (ESTADOS_EN_TRAMITE.includes(estado) || estado === 'EMITIDA') return null;
  return (
    <Aviso tono="info" titulo="Solicitud anterior al portal del cliente">
      Su estado era {ESTADO_ALTA[estado]?.texto.replace(' (anterior)', '').toLowerCase() || estado}. Se muestra solo para consulta.
    </Aviso>
  );
}

// ---------------------------------------------------------------------------
// Registro de cambios a los datos del formulario. Lo ven la marca y el personal.
// ---------------------------------------------------------------------------
const ORIGEN_CAMBIO = { MARCA: 'Marca', FIDELIS: 'Fidelis' };

function valorCambio(id, valor) {
  const vacio = valor === null || valor === undefined || valor === '' || (Array.isArray(valor) && !valor.length);
  if (vacio) return <span className="muted">vacío</span>;
  const campo = definicionCampo(id);
  const texto = campo ? textoValor(campo, valor) : typeof valor === 'object' ? JSON.stringify(valor) : String(valor);
  return texto || <span className="muted">vacío</span>;
}

function RegistroCambios({ id }) {
  const { data, isLoading, error, refetch } = useCambiosAlta(id);
  if (isLoading) return <Cargando />;
  if (error) return <ErrorCarga error={error} reintentar={refetch} />;
  if (!data?.length) return <p className="muted">Nadie ha cambiado los datos del formulario.</p>;
  return (
    <div className="stack">
      <p className="small muted">Cada cambio a los datos del formulario, lo más reciente primero. No se puede editar ni borrar.</p>
      <div className="tabla-marco">
        <table className="tabla">
          <thead>
            <tr><th>Fecha y hora</th><th>Quién</th><th>Origen</th><th>Momento</th><th>Dato</th><th>Antes</th><th>Después</th></tr>
          </thead>
          <tbody>
            {data.map((c, i) => (
              <tr key={`${c.fecha}-${c.campo}-${i}`}>
                <td className="small num">{fechaHora(c.fecha)}</td>
                <td className="small">{c.quien || 'Sin correo'}</td>
                <td className="small">{ORIGEN_CAMBIO[c.origen] || c.origen}</td>
                <td>
                  {c.etapa === 'ENVIADA'
                    ? <Estado texto="Después del envío" tono="atencion" />
                    : <span className="small muted">Antes del envío</span>}
                </td>
                <td className="small">{etiquetaCampo(c.campo)}</td>
                <td className="small">{valorCambio(c.campo, c.antes)}</td>
                <td className="small">{valorCambio(c.campo, c.despues)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Vista de la marca
// ---------------------------------------------------------------------------
function VistaMarca({ id }) {
  const { puede } = useAuth();
  const { data: a, isLoading, error, refetch } = useAltaMarca(id);
  const [pidiendoEnlace, setPidiendoEnlace] = useState(false);
  const volver = <Link to="/altas" className="volver"><ArrowLeft size={16} aria-hidden="true" /> Altas</Link>;

  if (isLoading) return <Cargando />;
  if (error) return <>{volver}<ErrorCarga error={error} reintentar={refetch} /></>;
  if (!a) return <>{volver}<Vacio titulo="No encontramos esta solicitud" /></>;

  const enTramite = ESTADOS_EN_TRAMITE.includes(a.estado_operativo);
  const faltan = categoriasFaltantes(a.faltantes);
  const f = a.fianza;

  return (
    <div style={{ maxWidth: 880 }}>
      <Encabezado volver={volver} titulo={nombre(a.afianzado_nombre)} descripcion={`${a.numero_solicitud} · ${nombre(a.beneficiario_nombre)}`} />
      <LineaDeTiempo estado={a.estado_operativo} />
      <div className="stack-lg">
        <div className="row"><Estado mapa={ESTADO_ALTA} valor={a.estado_operativo} /></div>
        <EstadoAnterior estado={a.estado_operativo} />
        {SIGUIENTE_PASO_MARCA[a.estado_operativo] && (
          <Aviso tono={a.estado_operativo === 'EMITIDA' ? 'ok' : faltan.length ? 'atencion' : 'info'} titulo={SIGUIENTE_PASO_MARCA[a.estado_operativo]}>
            {a.estado_operativo === 'EXPEDIENTE_RECIBIDO' && (faltan.length
              ? <p style={{ marginTop: '0.25rem' }}>Faltan {faltan.length === 1 ? 'un documento' : `${faltan.length} documentos`}: {faltan.map((c) => CATEGORIA_DOCUMENTO[c] || c).join(', ')}.</p>
              : <p style={{ marginTop: '0.25rem' }}>No falta ningún documento obligatorio.</p>)}
          </Aviso>
        )}
        {a.estado_operativo === 'EMITIDA' && (
          <section>
            <h2 style={{ fontSize: 'var(--t-lg)', marginBottom: '0.75rem' }}>Fianza emitida en FISO</h2>
            <Datos items={[
              ['Número de fianza', f ? <Link key="fianza" className="num" to={`/cartera/${f.id}`}>{f.fianza}</Link> : <span key="fianza" className="num">{a.fianza_emitida}</span>],
              f ? ['Vigencia', `${fecha(f.vigencia_desde)} al ${fecha(f.vigencia_hasta)}`] : null,
              f?.contrato_numero ? ['Contrato', `${f.contrato_numero}${f.contrato_fecha ? ` del ${fecha(f.contrato_fecha)}` : ''}`] : null,
              f ? ['Monto afianzado', <span key="monto" className="num">{q(f.monto_original)}</span>] : null,
              a.emitida_en ? ['Reconocida en la carga de FISO', fechaHora(a.emitida_en)] : null,
            ]} />
          </section>
        )}
        {enTramite && <AvanceExpediente id={a.id} esMarca />}
        <Datos items={[
          ['Monto solicitado', <span key="monto" className="num">{q(a.monto_solicitado)}</span>],
          ['Tipo de cliente', TIPO_PERSONA[a.tipo_persona]],
          ['Correo del distribuidor', a.afianzado_email],
          ['Celular del distribuidor', a.afianzado_telefono],
          ['Resolución de la marca', a.resolucion_marca_numero],
          ['Pedida el', fecha(a.created_at)],
          ['Formulario del distribuidor', a.ive_completado ? 'Enviado' : 'Pendiente'],
          a.enlace_expira && enTramite ? ['Enlace vigente hasta', fechaHora(a.enlace_expira)] : null,
        ]} />
        {enTramite && puede('corregirAlta') && (
          <section>
            <h2 style={{ fontSize: 'var(--t-lg)', marginBottom: '0.75rem' }}>Enlace del distribuidor</h2>
            <p className="muted" style={{ marginBottom: '0.75rem' }}>
              {a.estado_operativo === 'EXPEDIENTE_RECIBIDO'
                ? 'Genere un enlace para que el distribuidor suba los documentos que falten. Los datos del formulario los corrige usted desde Corregir datos y documentos.'
                : 'Si el distribuidor perdió el enlace o venció, genere uno nuevo. El anterior deja de funcionar y lo que ya llenó se conserva.'}
            </p>
            <button className="btn btn-secundario" onClick={() => setPidiendoEnlace(true)}>
              <Link2 size={16} aria-hidden="true" /> Generar enlace nuevo
            </button>
          </section>
        )}
        <section id="registro-cambios">
          <h2 style={{ fontSize: 'var(--t-lg)', marginBottom: '0.75rem' }}>Registro de cambios</h2>
          <RegistroCambios id={a.id} />
        </section>
        {pidiendoEnlace && (
          <EnviarEnlace solicitudId={a.id} correoInicial={a.afianzado_email} telefonoInicial={a.afianzado_telefono}
            afianzado={a.afianzado_nombre} marca={a.beneficiario_nombre} onCerrar={() => setPidiendoEnlace(false)} />
        )}
      </div>
    </div>
  );
}

function EnviarEnlace({ solicitudId, correoInicial, telefonoInicial, afianzado, marca, onCerrar }) {
  const reenviar = useReenviarEnlace();
  const [correo, setCorreo] = useState(correoInicial || '');
  const [telefono, setTelefono] = useState(telefonoInicial || '');
  const [tocados, setTocados] = useState({});
  const [r, setR] = useState(null);
  const [error, setError] = useState('');
  const errores = { correo: validateEmail(correo), telefono: validatePhone(telefono) };
  const tocar = (c) => () => setTocados((x) => ({ ...x, [c]: true }));

  function generar() {
    setTocados({ correo: true, telefono: true });
    if (errores.correo || errores.telefono) return;
    setError('');
    reenviar.mutateAsync({ id: solicitudId, correo: correo.trim(), telefono: telefono.trim() })
      .then(setR).catch((e) => setError(mensajeError(e)));
  }

  return (
    <Modal titulo="Enlace para el distribuidor" onCerrar={onCerrar}
      pie={!r && (
        <>
          <button className="btn btn-secundario" onClick={onCerrar}>Cancelar</button>
          <button className="btn btn-primario" disabled={reenviar.isPending} onClick={generar}>
            Generar enlace
          </button>
        </>
      )}>
      {error && <Aviso tono="critico">{error}</Aviso>}
      {r ? (
        <EnlacePortal token={r.token} expira={r.expires_at} afianzado={afianzado} correo={correo} telefono={telefono} marca={marca} />
      ) : (
        <div className="stack">
          <p>El enlace anterior deja de funcionar. El nuevo vale 7 días.</p>
          <Campo label="Correo del distribuidor" error={tocados.correo ? errores.correo : null}>
            {(p) => <input {...p} className="control" type="email" value={correo} onChange={(e) => setCorreo(e.target.value)} onBlur={tocar('correo')} />}
          </Campo>
          <Campo label="Celular del distribuidor" ayuda="Para enviarle el enlace por WhatsApp." error={tocados.telefono ? errores.telefono : null}>
            {(p) => <input {...p} className="control" type="tel" inputMode="tel" value={telefono} onChange={(e) => setTelefono(e.target.value)} onBlur={tocar('telefono')} />}
          </Campo>
        </div>
      )}
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Expediente para el personal de Fidelis: todo en un solo lugar, solo de consulta.
// ---------------------------------------------------------------------------
function DocumentoFila({ doc }) {
  const toast = useToast();
  return (
    <div className="archivo">
      <button className="btn btn-texto btn-sm" onClick={() => abrirDocumento(doc.file_path).catch(toast.error)}>
        <ExternalLink size={14} aria-hidden="true" /> <span className="nombre">{doc.nombre_archivo}</span>
      </button>
      <span className="muted">
        {tamanoArchivo(doc.file_size)} · {doc.origen === 'AFIANZADO' ? 'del distribuidor' : doc.origen === 'MARCA' ? 'de la marca' : 'cargado por Fidelis'} · {fecha(doc.created_at)}
      </span>
    </div>
  );
}

// Documentos retirados o reemplazados por quien los subio: no cuentan en el expediente.
const vigente = (d) => !(d.estado_revision === 'RECHAZADO' && /^(Reemplazado|Retirado)/.test(d.comentario_revision || ''));

function Documentos({ exp }) {
  const { solicitud, requisitos } = exp;
  const documentos = exp.documentos.filter(vigente);
  const faltan = new Set(categoriasFaltantes(solicitud.faltantes));
  const categoriasRequisito = new Set(requisitos.map((r) => r.categoria));
  const extras = documentos.filter((d) => !categoriasRequisito.has(d.categoria));

  return (
    <ul className="doc-lista">
      {requisitos
        .filter((r) => !['IVE_ASS_01', 'IVE_ASS_02'].includes(r.categoria))
        .map((r) => {
          const docs = documentos.filter((d) => d.categoria === r.categoria);
          return (
            <li key={r.id} className="doc">
              <div>
                <span className="doc-titulo">{r.nombre}</span>
                {!r.obligatorio && <span className="muted small"> (si aplica)</span>}
              </div>
              <div>
                {faltan.has(r.categoria)
                  ? <Estado texto="Falta" tono="critico" />
                  : docs.length ? <Estado texto="Entregado" tono="ok" /> : <Estado texto="No entregado" tono="neutro" />}
              </div>
              {docs.length > 0 && (
                <div className="doc-archivos">
                  {docs.map((d) => <DocumentoFila key={d.id} doc={d} />)}
                </div>
              )}
            </li>
          );
        })}
      {extras.map((d) => (
        <li key={d.id} className="doc">
          <span className="doc-titulo">{CATEGORIA_DOCUMENTO[d.categoria] || d.categoria}</span>
          <span />
          <div className="doc-archivos"><DocumentoFila doc={d} /></div>
        </li>
      ))}
    </ul>
  );
}

function FormularioIve({ solicitud }) {
  const ive = solicitud.ive_data;
  if (!ive) {
    return <Vacio titulo="El distribuidor aún no envía su formulario">{solicitud.ive_borrador ? 'Tiene un borrador guardado sin enviar.' : null}</Vacio>;
  }
  return (
    <div className="stack-lg">
      <p className="muted small">Enviado el {fechaHora(solicitud.ive_completed_at)} · versión {solicitud.ive_form_version}</p>
      {seccionesPara(solicitud.tipo_persona).map((s) => (
        <section key={s.titulo}>
          <h3 style={{ marginBottom: '0.75rem' }}>{s.titulo}</h3>
          <Datos items={camposVisibles(s, ive).map((c) => [c.label, textoValor(c, ive[c.id])])} />
        </section>
      ))}
      {solicitud.tipo_persona === 'INDIVIDUAL' && (
        <section>
          <h3 style={{ marginBottom: '0.75rem' }}>Datos del formato IVE calculados</h3>
          <Datos items={[
            ['Ingresos mensuales (rango IVE)', ive.ingresosMensuales],
            ['Egresos mensuales (rango IVE)', ive.egresosMensuales],
            ['Puesto', ive.cargoTrabajo],
            ['Empresa', ive.empresaNombre],
            ['Lugar', ive.lugarFirma],
          ]} />
        </section>
      )}
      <section>
        <h3 style={{ marginBottom: '0.75rem' }}>Declaración de veracidad</h3>
        <Datos items={[
          ['Aceptó la declaración de veracidad', ive.declaracionVeracidad ? `Sí, el ${fechaHora(solicitud.ive_completed_at)}` : 'No'],
          solicitud.ive_declaracion_version ? ['Texto aceptado', solicitud.ive_declaracion_version] : null,
          solicitud.ive_envio_hash
            ? ['Huella del envío', <span key="huella" className="num" title={solicitud.ive_envio_hash}>{solicitud.ive_envio_hash.slice(0, 12)}</span>]
            : null,
        ]} />
      </section>
    </div>
  );
}

function Resumen({ exp }) {
  const { solicitud, bandeja, marca } = exp;
  const consistencia = revisarConsistencia({ solicitud, ive: solicitud.ive_data });
  const etiqueta = { coincide: ['Coincide', 'ok'], difiere: ['No coincide', 'critico'], sin_dato: ['Sin dato', 'neutro'] };
  return (
    <div className="stack-lg">
      <ReferenciaDistribuidor solicitudId={solicitud.id} />
      <Datos items={[
        ['Distribuidor (según la marca)', nombre(solicitud.cliente_nombre_tmp)],
        solicitud.tipo_solicitud !== 'NUEVA' ? ['Tipo de solicitud', solicitud.tipo_solicitud === 'INCREMENTO' ? 'Incremento de una fianza vigente' : 'Renovación'] : null,
        exp.fianzaAnterior ? ['Fianza que cambia', <Link key="anterior" className="num" to={`/cartera/${exp.fianzaAnterior.id}`}>{exp.fianzaAnterior.fianza}</Link>] : null,
        ['Tipo de cliente', TIPO_PERSONA[solicitud.tipo_persona]],
        ['NIT', solicitud.cliente_nit_tmp],
        ['Correo', solicitud.cliente_email_tmp],
        ['Teléfono', solicitud.cliente_telefono_tmp],
        ['Marca', marca?.nombre],
        ['Monto solicitado', <span key="monto" className="num">{q(solicitud.monto_solicitado)}</span>],
        ['Ya afianzado con Fidelis', bandeja ? <span key="exposicion" className="num">{q(bandeja.exposicion_actual)} en {bandeja.marcas_con_poliza} marcas</span> : null],
        ['Resolución de la marca', solicitud.resolucion_marca_numero],
        ['Fecha de resolución', solicitud.resolucion_marca_fecha ? `${fecha(solicitud.resolucion_marca_fecha)} (vence ${fecha(bandeja?.resolucion_vence)})` : null],
        ['Límite aprobado por la marca', solicitud.resolucion_marca_monto ? <span key="limite" className="num">{q(solicitud.resolucion_marca_monto)}</span> : null],
        ['Plazo de crédito', solicitud.resolucion_marca_plazo_dias ? `${solicitud.resolucion_marca_plazo_dias} días` : null],
        solicitud.observaciones ? ['Notas de la marca', solicitud.observaciones] : null,
      ]} />
      <section>
        <h3 style={{ marginBottom: '0.75rem' }}>Consistencia entre la solicitud y el formulario</h3>
        <div className="tabla-marco">
          <table className="tabla">
            <thead><tr><th>Dato</th><th>Solicitud de la marca</th><th>Formulario del distribuidor</th><th>Resultado</th></tr></thead>
            <tbody>
              {consistencia.map((f) => (
                <tr key={f.dato}>
                  <td>{f.dato}</td>
                  <td>{f.moneda ? (f.marca ? q(f.marca) : '') : f.marca}</td>
                  <td>{f.moneda ? q(f.ive) : f.ive}</td>
                  <td><Estado texto={etiqueta[f.resultado][0]} tono={etiqueta[f.resultado][1]} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

function Historial({ revisiones }) {
  if (!revisiones?.length) return <p className="muted">Sin movimientos.</p>;
  return (
    <ul className="linea">
      {revisiones.map((r) => (
        <li key={r.id}>
          <div className="row"><Estado mapa={ESTADO_ALTA} valor={r.estado_nuevo} /><span className="small muted">{fechaHora(r.created_at)}</span></div>
          <p className="small" style={{ marginTop: '0.25rem' }}>
            {r.comentario}
            {r.monto_aprobado ? ` · ${q(r.monto_aprobado)}` : ''}
          </p>
          <p className="small muted">{r.autor?.full_name || (r.estado_nuevo === 'EMITIDA' ? 'Carga de FISO' : 'El distribuidor desde el portal')}</p>
        </li>
      ))}
    </ul>
  );
}

function Expediente({ id }) {
  const { data: exp, isLoading, error, refetch } = useExpediente(id);
  const cambios = useCambiosAlta(id);
  const toast = useToast();
  const [pestana, setPestana] = useState('resumen');
  const [descargando, setDescargando] = useState(false);
  const volver = <Link to="/altas" className="volver"><ArrowLeft size={16} aria-hidden="true" /> Solicitudes</Link>;

  if (isLoading) return <Cargando />;
  if (error) return <>{volver}<ErrorCarga error={error} reintentar={refetch} /></>;
  if (!exp) return <>{volver}<Vacio titulo="No encontramos esta solicitud" /></>;

  const { solicitud, fianzaEmitida } = exp;
  const estado = solicitud.estado_operativo;
  const documentos = exp.documentos.filter(vigente);
  const faltan = categoriasFaltantes(solicitud.faltantes);
  const alertas = alertasExpediente({ solicitud, ive: solicitud.ive_data });
  const cambiosTrasEnvio = (cambios.data || []).filter((c) => c.etapa === 'ENVIADA').length;

  async function descargar() {
    setDescargando(true);
    try {
      await descargarDocumentos(documentos, `${solicitud.numero_solicitud} `);
    } catch (e) {
      toast.error(e);
    } finally {
      setDescargando(false);
    }
  }

  return (
    <div>
      <Encabezado
        volver={volver}
        titulo={nombre(solicitud.cliente_nombre_tmp)}
        descripcion={`${solicitud.numero_solicitud} · ${nombre(exp.beneficiario?.nombre)} · pedida el ${fecha(solicitud.created_at)}`}
        acciones={documentos.length > 0 && (
          <button className="btn btn-secundario" onClick={descargar} disabled={descargando}>
            <Download size={18} aria-hidden="true" /> {descargando ? 'Descargando' : `Descargar expediente (${documentos.length})`}
          </button>
        )}
      />
      <LineaDeTiempo estado={estado} />
      <div className="dos-columnas">
        <div>
          <Pestanas
            valor={pestana}
            onCambiar={setPestana}
            opciones={[
              { valor: 'resumen', texto: 'Resumen' },
              { valor: 'documentos', texto: 'Documentos', contador: faltan.length ? `faltan ${faltan.length}` : null },
              { valor: 'ive', texto: 'Formulario IVE' },
              { valor: 'historial', texto: 'Historial' },
              { valor: 'cambios', texto: 'Registro de cambios', contador: cambios.data?.length || null },
            ]}
          />
          {pestana === 'resumen' && <Resumen exp={exp} />}
          {pestana === 'documentos' && <Documentos exp={exp} />}
          {pestana === 'ive' && <FormularioIve solicitud={solicitud} />}
          {pestana === 'historial' && <Historial revisiones={exp.revisiones} />}
          {pestana === 'cambios' && <RegistroCambios id={solicitud.id} />}
        </div>

        <aside className="lateral" aria-label="Estado de la solicitud">
          <div>
            <Estado mapa={ESTADO_ALTA} valor={estado} />
            <p className="valor num" style={{ fontFamily: 'var(--fuente-titulo)', fontSize: '1.6rem', fontWeight: 600, marginTop: '0.5rem' }}>
              {q(fianzaEmitida?.monto_original || solicitud.monto_solicitado)}
            </p>
            <p className="small muted">{fianzaEmitida ? 'emitido en FISO' : 'solicitado'} · {TIPO_PERSONA[solicitud.tipo_persona]}</p>
          </div>

          {fianzaEmitida && (
            <Datos items={[
              ['Fianza', <Link key="fianza" className="num" to={`/cartera/${fianzaEmitida.id}`}>{fianzaEmitida.fianza}</Link>],
              ['Vigencia', `${fecha(fianzaEmitida.vigencia_desde)} al ${fecha(fianzaEmitida.vigencia_hasta)}`],
              fianzaEmitida.contrato_numero ? ['Contrato', fianzaEmitida.contrato_numero] : null,
            ]} />
          )}

          {estado === 'EXPEDIENTE_RECIBIDO' && (
            faltan.length
              ? <p className="small">Faltan: {faltan.map((c) => CATEGORIA_DOCUMENTO[c] || c).join(', ')}.</p>
              : <p className="small">No falta ningún documento obligatorio.</p>
          )}

          {(alertas.length > 0 || cambiosTrasEnvio > 0) && (
            <ul className="alerta-lista">
              {cambiosTrasEnvio > 0 && (
                <li>
                  <Estado texto="Cambios" tono="atencion" />
                  <span>
                    La marca corrigió {cambiosTrasEnvio} {cambiosTrasEnvio === 1 ? 'dato' : 'datos'} después del envío del distribuidor.
                    {' '}<button type="button" className="btn btn-texto btn-sm" onClick={() => setPestana('cambios')}>Ver registro de cambios</button>
                  </span>
                </li>
              )}
              {alertas.map((a) => (
                <li key={a.texto}><Estado texto={a.tono === 'critico' ? 'Alerta' : 'Nota'} tono={a.tono} /> {a.texto}</li>
              ))}
            </ul>
          )}

          <EstadoAnterior estado={estado} />
          <p className="small muted">
            Solo de consulta. La decisión y la emisión se hacen en FISO. Cuando la fianza llega en la carga diaria, la solicitud queda emitida sola.
          </p>
        </aside>
      </div>
    </div>
  );
}

export default function AltaDetalle() {
  const { id } = useParams();
  const { puede } = useAuth();
  return puede('verExpedientes') ? <Expediente id={id} /> : <VistaMarca id={id} />;
}
