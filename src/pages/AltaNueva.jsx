import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { ArrowLeft, ArrowRight, CheckCircle2, FileText } from 'lucide-react';
import { useAuth } from '../auth/AuthProvider';
import { Aviso, Campo, Cargando, Datos, Encabezado, Estado } from '../components/ui';
import EnlacePortal from '../components/EnlacePortal';
import { useFianza, useMarcas } from '../data/cartera';
import { useRequisitos, useSolicitarAlta } from '../data/altas';
import { useCondicionesMarca, useFianzasDelAfianzado, useVincularFianzaAnterior } from '../data/operacion';
import { resumenCondiciones } from '../domain/condiciones';
import { useDebounce } from '../lib/useDebounce';
import { calcularPrima } from '../domain/primas';
import { validateDPI, validateEmail, validateNIT, validatePhone } from '../domain/validators';
import { fecha, hoyISO, nombre, q } from '../lib/format';
import { mensajeError } from '../lib/errores';

const VACIO = {
  tipoSolicitud: 'NUEVA',
  beneficiarioCodigo: '',
  tipoPersona: 'INDIVIDUAL',
  nombres: '',
  apellidos: '',
  razonSocial: '',
  dpi: '',
  nit: '',
  correo: '',
  telefono: '',
  monto: '',
  resolucionNumero: '',
  resolucionFecha: '',
  resolucionMonto: '',
  resolucionPlazo: '90',
  observaciones: '',
};

// Oracle no guarda si el cliente es persona o sociedad. La razon social lo delata casi siempre.
const PARECE_SOCIEDAD = /(\bS\.?\s?A\.?$|SOCIEDAD|LIMITADA|\bLTDA\b|\bS\.?\s?R\.?\s?L\b|\bCIA\b|COMPA[NÑ]IA|CORPORACI[OÓ]N)/i;

// Datos de la fianza que se renueva, para no escribirlos otra vez.
function precargaRenovacion(f) {
  const nombreCliente = nombre(f.cliente_nombre);
  const juridica = PARECE_SOCIEDAD.test(nombreCliente);
  // Oracle suele traer "APELLIDOS, NOMBRES". Sin coma no se adivina: la marca separa nombres y apellidos.
  const [antes, despues] = nombreCliente.split(',').map((x) => x.trim());
  return {
    tipoSolicitud: 'RENOVACION',
    fianzaAnterior: f,
    tipoPersona: juridica ? 'JURIDICA' : 'INDIVIDUAL',
    ...(juridica
      ? { razonSocial: nombreCliente }
      : despues ? { nombres: despues, apellidos: antes } : { nombres: nombreCliente, apellidos: '' }),
    nit: f.cliente_nit || '',
    monto: f.monto_original ? String(Number(f.monto_original)) : '',
    beneficiarioCodigo: f.beneficiario_codigo ? String(f.beneficiario_codigo) : '',
  };
}

const nombreCompleto = (d) => (d.tipoPersona === 'JURIDICA' ? d.razonSocial : `${d.nombres} ${d.apellidos}`).replace(/\s+/g, ' ').trim();

function validar(d) {
  const e = {};
  if (!d.beneficiarioCodigo) e.beneficiarioCodigo = 'Elija la empresa.';
  if (d.tipoPersona === 'JURIDICA') {
    if (d.razonSocial.trim().length < 3) e.razonSocial = 'Escriba la razón social.';
  } else {
    if (!d.nombres.trim()) e.nombres = 'Escriba los nombres.';
    if (!d.apellidos.trim()) e.apellidos = 'Escriba los apellidos.';
    if (d.dpi) {
      const dpi = validateDPI(d.dpi);
      if (dpi) e.dpi = dpi;
    }
  }
  const correo = validateEmail(d.correo);
  if (correo) e.correo = correo;
  // Correo y celular son obligatorios: el enlace se envía por los dos.
  const tel = validatePhone(d.telefono);
  if (tel) e.telefono = tel;
  if (d.nit) {
    const nit = validateNIT(d.nit);
    if (nit) e.nit = nit;
  }
  if (!(Number(d.monto) > 0)) e.monto = 'Indique el monto de la fianza.';
  if (d.resolucionMonto && Number(d.monto) > Number(d.resolucionMonto)) e.monto = 'El monto no puede pasar del límite que aprobó su empresa.';
  if (d.tipoSolicitud !== 'NUEVA' && !d.fianzaAnterior) e.fianzaAnterior = 'Elija la fianza que se incrementa o renueva.';
  if (d.tipoSolicitud === 'INCREMENTO' && d.fianzaAnterior && Number(d.monto) <= Number(d.fianzaAnterior.monto_original)) {
    e.monto = `Para un incremento el monto debe ser mayor que el actual (${q(d.fianzaAnterior.monto_original)}).`;
  }
  if (!d.resolucionNumero.trim()) e.resolucionNumero = 'Indique el número de la carta o nota de aprobación.';
  if (!d.resolucionFecha) e.resolucionFecha = 'Indique la fecha de la aprobación.';
  else if (d.resolucionFecha > hoyISO()) e.resolucionFecha = 'La fecha no puede ser futura.';
  return e;
}

// Lo que se le va a pedir, a la vista desde el primer paso.
function DocumentosNecesarios({ tipoPersona }) {
  const { data = [] } = useRequisitos(tipoPersona);
  const deLaMarca = data.filter((r) => r.responsable === 'MARCA');
  const delDistribuidor = data.filter((r) => r.responsable !== 'MARCA');
  return (
    <aside className="lateral" aria-label="Documentos que se necesitan">
      <div>
        <h3 style={{ fontSize: 'var(--t-md)' }}><FileText size={18} aria-hidden="true" style={{ verticalAlign: '-3px' }} /> Documentos que se necesitan</h3>
        <p className="small muted" style={{ marginTop: '0.35rem' }}>
          Usted o el distribuidor pueden subirlos, también con foto desde el teléfono. Lo que usted adelante, él ya no lo tiene que hacer.
        </p>
      </div>
      {deLaMarca.length > 0 && (
        <div>
          <span className="etiqueta">Los sube usted</span>
          <ul className="lista-docs">{deLaMarca.map((r) => <li key={r.categoria}>{r.nombre}</li>)}</ul>
        </div>
      )}
      <div>
        <span className="etiqueta">Del distribuidor</span>
        <ul className="lista-docs">
          {delDistribuidor.map((r) => (
            <li key={r.categoria}>
              {r.nombre}
              {!r.obligatorio && <span className="muted"> (si aplica)</span>}
            </li>
          ))}
        </ul>
      </div>
      <p className="small muted">Además, el distribuidor llena un formulario corto de 5 partes. Los datos que usted escriba aquí ya le aparecen llenos.</p>
    </aside>
  );
}

export default function AltaNueva() {
  const { usuario } = useAuth();
  const navegar = useNavigate();
  const marcas = useMarcas();
  const solicitar = useSolicitarAlta();
  const vincular = useVincularFianzaAnterior();
  const condiciones = useCondicionesMarca();
  const [params] = useSearchParams();
  const idRenovar = params.get('renovar') || '';
  const renovar = useFianza(idRenovar);
  const precargado = useRef('');
  const [busqueda, setBusqueda] = useState('');
  const busquedaLenta = useDebounce(busqueda, 300);
  const [d, setD] = useState(VACIO);
  const [errores, setErrores] = useState({});
  const [errorGeneral, setErrorGeneral] = useState('');
  const [resultado, setResultado] = useState(null);

  const beneficiarios = useMemo(() => {
    const lista = [];
    for (const m of marcas.data || []) {
      for (const b of m.beneficiarios) lista.push({ ...b, marca: m.nombre, marcaId: m.id, tarifa: m.tarifa_prima });
    }
    return lista.sort((a, b) => a.marca.localeCompare(b.marca) || a.nombre.localeCompare(b.nombre));
  }, [marcas.data]);

  const elegido = beneficiarios.find((b) => String(b.codigo_contacto) === String(d.beneficiarioCodigo));
  useEffect(() => {
    if (beneficiarios.length === 1) setD((x) => (x.beneficiarioCodigo ? x : { ...x, beneficiarioCodigo: String(beneficiarios[0].codigo_contacto) }));
  }, [beneficiarios]);
  // Renovar desde la fianza o desde Vencen pronto: el formulario llega lleno.
  useEffect(() => {
    if (!renovar.data || precargado.current === idRenovar) return;
    precargado.current = idRenovar;
    setD((x) => ({ ...x, ...precargaRenovacion(renovar.data) }));
  }, [renovar.data, idRenovar]);
  const cond = condiciones.data?.find((c) => c.grupo_id === elegido?.marcaId);
  const candidatas = useFianzasDelAfianzado(d.tipoSolicitud !== 'NUEVA' ? busquedaLenta : '', elegido?.marcaId);
  useEffect(() => {
    if (cond?.monto_sugerido && d.tipoSolicitud === 'NUEVA') setD((x) => (x.monto ? x : { ...x, monto: String(cond.monto_sugerido) }));
  }, [cond?.monto_sugerido, d.tipoSolicitud]);

  function elegirAnterior(f) {
    setD((x) => ({
      ...x, fianzaAnterior: f,
      ...(x.tipoPersona === 'JURIDICA' ? { razonSocial: nombre(f.cliente_nombre) } : { nombres: nombre(f.cliente_nombre), apellidos: '' }),
      nit: f.cliente_nit || x.nit,
      beneficiarioCodigo: f.beneficiario_codigo ? String(f.beneficiario_codigo) : x.beneficiarioCodigo,
    }));
    setBusqueda('');
  }

  const estimado = Number(d.monto) > 0 ? calcularPrima(Number(d.monto), { tarifa: elegido?.tarifa }) : null;
  const set = (campo) => (e) => setD((x) => ({ ...x, [campo]: e.target.value }));

  async function enviar(e) {
    e.preventDefault();
    setErrorGeneral('');
    const errs = validar(d);
    setErrores(errs);
    if (Object.keys(errs).length) return;
    try {
      const r = await solicitar.mutateAsync({ ...d, nombre: nombreCompleto(d) });
      if (d.tipoSolicitud !== 'NUEVA' && d.fianzaAnterior) {
        await vincular.mutateAsync({ solicitudId: r.solicitud_id, fianzaId: d.fianzaAnterior.id, tipo: d.tipoSolicitud });
      }
      setResultado(r);
      window.scrollTo({ top: 0 });
    } catch (err) {
      setErrorGeneral(mensajeError(err));
    }
  }

  const volver = <Link to="/altas" className="volver"><ArrowLeft size={16} aria-hidden="true" /> Altas</Link>;

  if (resultado) {
    return (
      <div style={{ maxWidth: 760 }}>
        {volver}
        <Encabezado titulo="Solicitud creada" descripcion={`${resultado.numero_solicitud} · ${nombreCompleto(d)}`} />
        <div className="stack-lg">
          <Aviso tono="ok" titulo="Dos cosas pueden avanzar al mismo tiempo">
            Envíele el enlace al distribuidor para que llene su parte desde el teléfono. Mientras tanto, usted puede adelantar datos y
            subir documentos que ya tenga, como su carta de aprobación. Los dos ven lo mismo.
          </Aviso>
          <button className="btn btn-primario" style={{ alignSelf: 'flex-start' }} onClick={() => navegar(`/altas/${resultado.solicitud_id}/completar`)}>
            Adelantar datos y documentos <ArrowRight size={16} aria-hidden="true" />
          </button>
          <EnlacePortal
            token={resultado.ive_token}
            expira={resultado.ive_expira}
            afianzado={nombreCompleto(d)}
            correo={d.correo}
            telefono={d.telefono}
            marca={elegido?.marca || elegido?.nombre}
          />
          <div className="row">
            <button className="btn btn-secundario" onClick={() => navegar(`/altas/${resultado.solicitud_id}`)}>Ver el avance</button>
            <button className="btn btn-texto" onClick={() => { setD(VACIO); setResultado(null); }}>Solicitar otra</button>
          </div>
        </div>
      </div>
    );
  }

  if (marcas.isLoading || (idRenovar && renovar.isLoading)) return <Cargando />;

  return (
    <div>
      <Encabezado
        volver={volver}
        titulo={d.tipoSolicitud === 'RENOVACION' && d.fianzaAnterior ? `Renovar la fianza ${d.fianzaAnterior.fianza}` : 'Nueva fianza para un distribuidor'}
        descripcion={d.tipoSolicitud === 'RENOVACION' && d.fianzaAnterior
          ? 'Ya llenamos lo que conocemos de la fianza actual. Revise el monto, agregue el celular y el correo del distribuidor y la aprobación de su empresa.'
          : 'Escriba lo básico. El distribuidor completa el resto desde su teléfono, y usted puede adelantar lo que quiera.'}
      />
      {idRenovar && !renovar.isLoading && !renovar.data && (
        <div style={{ marginBottom: '1rem' }}>
          <Aviso tono="atencion">No encontramos la fianza que quiere renovar. Búsquela abajo en Renovar una fianza.</Aviso>
        </div>
      )}
      <div className="dos-columnas">
        <form onSubmit={enviar} noValidate>
          {errorGeneral && <div style={{ marginBottom: '1rem' }}><Aviso tono="critico">{errorGeneral}</Aviso></div>}

          <section className="bloque-form">
            <h3>Qué necesita</h3>
            <div className="opciones" role="radiogroup" aria-label="Tipo de solicitud">
              {[['NUEVA', 'Distribuidor nuevo'], ['INCREMENTO', 'Subir el monto de un distribuidor'], ['RENOVACION', 'Renovar una fianza']].map(([v, t]) => (
                <label key={v} className="opcion">
                  <input type="radio" name="tipoSolicitud" value={v} checked={d.tipoSolicitud === v}
                    onChange={(e) => setD((x) => ({ ...x, tipoSolicitud: e.target.value, fianzaAnterior: null }))} />
                  {t}
                </label>
              ))}
            </div>
            {d.tipoSolicitud !== 'NUEVA' && (
              <div className="stack" style={{ marginTop: '1rem' }}>
                {d.fianzaAnterior ? (
                  <Aviso tono="info" titulo={`Fianza ${d.fianzaAnterior.fianza} · ${nombre(d.fianzaAnterior.cliente_nombre)}`}
                    accion={<button type="button" className="btn btn-texto btn-sm" onClick={() => setD((x) => ({ ...x, fianzaAnterior: null }))}>Cambiar</button>}>
                    Monto actual {q(d.fianzaAnterior.monto_original)}, vence el {fecha(d.fianzaAnterior.vigencia_hasta)}.
                    {d.tipoSolicitud === 'INCREMENTO' && cond && (cond.incremento === 'MODIFICACION'
                      ? ' Se modifica la misma fianza.'
                      : ' Se emite una fianza nueva por el monto total y la anterior se cancela al emitirla.')}
                  </Aviso>
                ) : (
                  <Campo label="Busque la fianza vigente" error={errores.fianzaAnterior} ayuda="Número de fianza o nombre del distribuidor.">
                    {(p) => <input {...p} className="control" value={busqueda} onChange={(e) => setBusqueda(e.target.value)} autoComplete="off" />}
                  </Campo>
                )}
                {!d.fianzaAnterior && candidatas.data?.length > 0 && (
                  <ul className="tareas" style={{ border: '1px solid var(--borde)', borderRadius: 'var(--r-md)' }}>
                    {candidatas.data.map((f) => (
                      <li key={f.id}>
                        <button type="button" className="tarea" style={{ width: '100%', background: 'none', border: 0, textAlign: 'left', cursor: 'pointer' }} onClick={() => elegirAnterior(f)}>
                          <span className="tarea-texto">
                            <strong>{f.fianza} · {nombre(f.cliente_nombre)}</strong>
                            <span className="sub">{q(f.monto_original)} · vence {fecha(f.vigencia_hasta)}</span>
                          </span>
                          <Estado texto="Elegir" tono="activo" />
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
                {!d.fianzaAnterior && busquedaLenta.trim().length >= 3 && candidatas.data?.length === 0 && (
                  <p className="small muted">No hay fianzas vigentes con esa búsqueda.</p>
                )}
              </div>
            )}
          </section>

          <section className="bloque-form">
            <h3>El distribuidor</h3>
            <div className="stack">
              <div className="opciones" role="radiogroup" aria-label="Tipo de distribuidor">
                {[['INDIVIDUAL', 'Persona o comerciante individual'], ['JURIDICA', 'Empresa (sociedad)']].map(([v, t]) => (
                  <label key={v} className="opcion">
                    <input type="radio" name="tipoPersona" value={v} checked={d.tipoPersona === v} onChange={set('tipoPersona')} />
                    {t}
                  </label>
                ))}
              </div>
              <div className="grid-2">
                {d.tipoPersona === 'JURIDICA' ? (
                  <Campo label="Razón social" error={errores.razonSocial} className="completo">
                    {(p) => <input {...p} className="control" value={d.razonSocial} onChange={set('razonSocial')} autoComplete="off" />}
                  </Campo>
                ) : (
                  <>
                    <Campo label="Nombres" error={errores.nombres}>
                      {(p) => <input {...p} className="control" value={d.nombres} onChange={set('nombres')} autoComplete="off" />}
                    </Campo>
                    <Campo label="Apellidos" error={errores.apellidos}>
                      {(p) => <input {...p} className="control" value={d.apellidos} onChange={set('apellidos')} autoComplete="off" />}
                    </Campo>
                    <Campo label="DPI (CUI)" opcional error={errores.dpi} ayuda="Si lo tiene, el distribuidor ya no lo escribe.">
                      {(p) => <input {...p} className="control" inputMode="numeric" value={d.dpi} onChange={set('dpi')} />}
                    </Campo>
                  </>
                )}
                <Campo label="NIT" opcional error={errores.nit} ayuda="Con el NIT reconocemos si ya es cliente de Fidelis.">
                  {(p) => <input {...p} className="control" value={d.nit} onChange={set('nit')} />}
                </Campo>
                <Campo label="Celular (WhatsApp)" error={errores.telefono} ayuda="Para enviarle el enlace por WhatsApp.">
                  {(p) => <input {...p} className="control" type="tel" inputMode="tel" value={d.telefono} onChange={set('telefono')} />}
                </Campo>
                <Campo label="Correo" error={errores.correo}>
                  {(p) => <input {...p} className="control" type="email" value={d.correo} onChange={set('correo')} />}
                </Campo>
              </div>
            </div>
          </section>

          <section className="bloque-form">
            <h3>Fianza</h3>
            {(beneficiarios.length > 1 || !usuario.esMarca) && (
              <div className="grid-2" style={{ marginBottom: '1rem' }}>
                <Campo label={usuario.esMarca ? 'Empresa de su grupo que entrega la mercadería' : 'Beneficiario'} error={errores.beneficiarioCodigo} className="completo">
                  {(p) => (
                    <select {...p} className="control" value={d.beneficiarioCodigo} onChange={set('beneficiarioCodigo')}>
                      <option value="">Elija</option>
                      {beneficiarios.map((b) => (
                        <option key={b.id} value={b.codigo_contacto}>{nombre(b.nombre)}{usuario.esPersonal ? ` (${b.marca})` : ''}</option>
                      ))}
                    </select>
                  )}
                </Campo>
              </div>
            )}
            <div className="grid-2">
              <Campo label={d.tipoSolicitud === 'INCREMENTO' ? 'Monto total después del incremento (Q)' : 'Monto de la fianza (Q)'} error={errores.monto}
                ayuda={cond?.monto_sugerido && d.tipoSolicitud === 'NUEVA' ? `Monto usual para un distribuidor nuevo: ${q(cond.monto_sugerido)}.` : 'El valor de la mercadería que va a tener en consignación.'}>
                {(p) => <input {...p} className="control" inputMode="decimal" value={d.monto} onChange={set('monto')} />}
              </Campo>
              <div className="campo">
                <span className="etiqueta">Costo estimado de la fianza</span>
                {estimado ? (
                  <p className="num" style={{ paddingTop: '0.6rem' }}>
                    <strong>{q(estimado.total)}</strong> al año
                    <span className="sub">Incluye derechos e IVA.</span>
                  </p>
                ) : <p className="muted small" style={{ paddingTop: '0.6rem' }}>Indique el monto.</p>}
              </div>
            </div>
            {cond && (
              <div style={{ marginTop: '1rem' }}>
                <span className="etiqueta">Condiciones de {cond.grupo?.nombre}</span>
                <Datos items={resumenCondiciones(cond).slice(0, 4)} />
              </div>
            )}
          </section>

          <section className="bloque-form">
            <h3>Aprobación de crédito de su empresa</h3>
            <p className="small muted" style={{ marginBottom: '0.75rem' }}>La carta o nota con la que su empresa aprobó al distribuidor. Puede subir el documento después.</p>
            <div className="grid-2">
              <Campo label="Número de la carta o nota" error={errores.resolucionNumero}>
                {(p) => <input {...p} className="control" value={d.resolucionNumero} onChange={set('resolucionNumero')} />}
              </Campo>
              <Campo label="Fecha" error={errores.resolucionFecha} ayuda="Desde esta fecha hay 30 días para firmar el contrato.">
                {(p) => <input {...p} className="control" type="date" max={hoyISO()} value={d.resolucionFecha} onChange={set('resolucionFecha')} />}
              </Campo>
              <Campo label="Límite aprobado (Q)" opcional>
                {(p) => <input {...p} className="control" inputMode="decimal" value={d.resolucionMonto} onChange={set('resolucionMonto')} />}
              </Campo>
              <Campo label="Plazo de crédito (días)" opcional>
                {(p) => <input {...p} className="control" inputMode="numeric" value={d.resolucionPlazo} onChange={set('resolucionPlazo')} />}
              </Campo>
            </div>
            <div style={{ marginTop: '1rem' }}>
              <Campo label="Notas para Fidelis" opcional>
                {(p) => <textarea {...p} className="control" value={d.observaciones} onChange={set('observaciones')} />}
              </Campo>
            </div>
          </section>

          <div className="acciones">
            <Link className="btn btn-secundario" to="/altas">Cancelar</Link>
            <button className="btn btn-primario" type="submit" disabled={solicitar.isPending}>
              {solicitar.isPending ? 'Creando' : 'Crear solicitud'} <CheckCircle2 size={16} aria-hidden="true" />
            </button>
          </div>
        </form>
        <DocumentosNecesarios tipoPersona={d.tipoPersona} />
      </div>
    </div>
  );
}
