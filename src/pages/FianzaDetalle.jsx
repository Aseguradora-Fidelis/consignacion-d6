import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { AlertOctagon, ArrowLeft, FileMinus2, Printer, RefreshCw, UserSearch } from 'lucide-react';
import ReportarIncumplimiento from '../components/ReportarIncumplimiento';
import { useAuth } from '../auth/AuthProvider';
import { Aviso, Campo, Cargando, Datos, Encabezado, ErrorCarga, Estado, Modal, Vacio } from '../components/ui';
import { useToast } from '../components/ui/Toasts';
import { useFianza, useSolicitarBaja } from '../data/cartera';
import { ESTADO_BAJA, ESTADO_POLIZA, TIPO_BAJA } from '../domain/estados';
import { MOVIMIENTO } from '../domain/glosario';
import { diasHasta, fecha, fechaHora, isoDe, mes, nombre, q } from '../lib/format';
import { esc } from '../lib/html';
import { mensajeError } from '../lib/errores';

function imprimirConstancia(f, esMarca) {
  const ventana = window.open('', '_blank', 'width=900,height=1000');
  if (!ventana) return;
  ventana.opener = null;
  const filas = [
    ['Fianza', `${f.fianza}${f.endoso && !esMarca ? ` (endoso ${f.endoso})` : ''}`],
    ['Clase', 'D-6 Consignación comercial'],
    [esMarca ? 'Distribuidor' : 'Afianzado', nombre(f.cliente_nombre)],
    ['Beneficiario', nombre(f.beneficiario_nombre)],
    ['Monto afianzado', q(f.monto_original)],
    ['Vigencia', `${fecha(f.vigencia_desde)} al ${fecha(f.vigencia_hasta)}`],
    ['Contrato', f.contrato_numero || ''],
    ['Estado', ESTADO_POLIZA[f.estado]?.texto || f.estado],
  ];
  ventana.document.write(`<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Constancia ${esc(f.fianza)}</title>
<style>
body{font-family:Roboto,Arial,sans-serif;color:#111;margin:48px;font-size:14px}
img{height:56px}h1{font-family:Poppins,Arial,sans-serif;font-size:22px;margin:32px 0 8px}
table{width:100%;border-collapse:collapse;margin-top:24px}td{padding:10px 8px;border-bottom:1px solid #e0e0e0;vertical-align:top}
td:first-child{color:#4a4a4a;width:200px}.pie{margin-top:48px;font-size:12px;color:#4a4a4a}
</style></head><body>
<img src="${esc(window.location.origin)}/brand/fidelis-fianzas.svg" alt="Fidelis Fianzas">
<h1>Constancia de fianza de consignación</h1>
<p>Información registrada en el sistema de Fidelis al ${esc(fechaHora(new Date()))}.</p>
<table>${filas.map(([a, b]) => `<tr><td>${esc(a)}</td><td>${esc(b)}</td></tr>`).join('')}</table>
<p class="pie">Esta constancia no sustituye la póliza emitida. Para verificar su validez llame al 2285 7000.</p>
<script>window.onload=function(){window.print()}</script>
</body></html>`);
  ventana.document.close();
}

function SolicitarBaja({ fianza, onCerrar }) {
  const toast = useToast();
  const solicitar = useSolicitarBaja();
  const [tipo, setTipo] = useState('DEVOLUCION_MERCADERIA');
  const [motivo, setMotivo] = useState('');
  const [carta, setCarta] = useState(null);
  const [error, setError] = useState('');
  const hoy = new Date();
  const meses = Array.from({ length: 12 }, (_, i) => isoDe(new Date(hoy.getFullYear(), hoy.getMonth() + i + 1, 0)))
    .filter((m, i) => i === 0 || m <= fianza.vigencia_hasta);
  const venceAntes = fianza.vigencia_hasta < meses[0];
  const [fechaEfectiva, setFechaEfectiva] = useState(meses[0]);

  async function enviar() {
    setError('');
    if (!motivo.trim()) {
      setError('Describa el motivo.');
      return;
    }
    if (carta && carta.size > 15 * 1024 * 1024) {
      setError('La carta debe pesar menos de 15 MB.');
      return;
    }
    try {
      const r = await solicitar.mutateAsync({
        fianzaId: fianza.id, tipo, motivo: motivo.trim(), fechaEfectiva, carta,
      });
      toast.ok(`Baja ${r.numero_solicitud} enviada a Fidelis. Cancela el ${fecha(r.fecha_efectiva)}.`);
      onCerrar();
    } catch (e) {
      setError(mensajeError(e));
    }
  }

  return (
    <Modal
      titulo={`Pedir la baja de la fianza ${fianza.fianza}`}
      subtitulo={nombre(fianza.cliente_nombre)}
      onCerrar={onCerrar}
      pie={(
        <>
          <button className="btn btn-secundario" onClick={onCerrar}>Cancelar</button>
          <button className="btn btn-primario" onClick={enviar} disabled={solicitar.isPending}>
            {solicitar.isPending ? 'Enviando' : 'Enviar solicitud'}
          </button>
        </>
      )}
    >
      <div className="stack">
        {error && <Aviso tono="critico">{error}</Aviso>}
        {venceAntes && (
          <Aviso tono="atencion" titulo={`Esta fianza vence el ${fecha(fianza.vigencia_hasta)}`}>
            Si no la va a renovar, no necesita pedir la baja: basta con no pedir la renovación. Pida la baja solo si debe
            cancelarse antes de esa fecha.
          </Aviso>
        )}
        <Campo label="Motivo">
          {(p) => (
            <select {...p} className="control" value={tipo} onChange={(e) => setTipo(e.target.value)}>
              {Object.entries(TIPO_BAJA).map(([v, t]) => <option key={v} value={v}>{t}</option>)}
            </select>
          )}
        </Campo>
        <Campo label="Fecha de cancelación" ayuda="La baja surte efecto al cierre del mes que elija. Hasta esa fecha la fianza sigue vigente.">
          {(p) => (
            <select {...p} className="control" value={fechaEfectiva} onChange={(e) => setFechaEfectiva(e.target.value)}>
              {meses.map((m, i) => <option key={m} value={m}>{fecha(m)} ({i === 0 ? 'este mes' : mes(m).toLowerCase()})</option>)}
            </select>
          )}
        </Campo>
        <Campo label="Detalle" ayuda="Por ejemplo: el distribuidor devolvió el inventario y cerró el punto de venta.">
          {(p) => <textarea {...p} className="control" value={motivo} onChange={(e) => setMotivo(e.target.value)} />}
        </Campo>
        <Campo label="Carta de la marca" opcional ayuda="PDF o imagen, hasta 15 MB.">
          {(p) => <input {...p} type="file" accept="application/pdf,image/png,image/jpeg" onChange={(e) => setCarta(e.target.files?.[0] || null)} />}
        </Campo>
        <Aviso>
          La fianza se cancela el {fecha(fechaEfectiva)} y ese mes se cobra completo. La baja aparece procesada cuando FISO cancela
          la fianza.
        </Aviso>
      </div>
    </Modal>
  );
}

export default function FianzaDetalle() {
  const { id } = useParams();
  const { puede, usuario } = useAuth();
  const esMarca = usuario.esMarca;
  const { data: f, isLoading, error, refetch } = useFianza(id);
  const [bajaAbierta, setBajaAbierta] = useState(false);
  const [reclamoAbierto, setReclamoAbierto] = useState(false);

  const volver = <Link to="/cartera" className="volver"><ArrowLeft size={16} aria-hidden="true" /> Cartera</Link>;
  if (isLoading) return <Cargando />;
  if (error) return <>{volver}<ErrorCarga error={error} reintentar={refetch} /></>;
  if (!f) return <>{volver}<Vacio titulo="No encontramos esta fianza">Puede que no pertenezca a su cartera.</Vacio></>;

  // Una baja pedida sigue pendiente hasta que FISO cancela la fianza.
  const canceladaEnFiso = ['CANCELADA', 'ANULADA'].includes(f.operational_status);
  const bajaPendiente = !canceladaEnFiso && f.bajas?.some((b) => ['PENDIENTE_REVISION', 'APROBADA'].includes(b.estado));
  const puedePedirBaja = puede('solicitarBaja') && ['VIGENTE', 'POR_RENOVAR', 'VENCIDA'].includes(f.estado) && !bajaPendiente;
  const puedeRenovar = puede('solicitarAlta') && ['VIGENTE', 'POR_RENOVAR', 'VENCIDA'].includes(f.estado);
  // A 60 dias o menos del vencimiento lo normal es renovar: Renovar pasa a ser el boton principal.
  const dias = diasHasta(f.vigencia_hasta);
  const renovarPrimero = puedeRenovar && dias !== null && dias <= 60;
  const botonRenovar = puedeRenovar && (
    <Link className={`btn ${renovarPrimero ? 'btn-primario' : 'btn-secundario'}`} to={`/altas/nueva?renovar=${f.id}`}>
      <RefreshCw size={18} aria-hidden="true" /> Renovar
    </Link>
  );
  const botonBaja = puedePedirBaja && (
    <button className={`btn ${renovarPrimero ? 'btn-secundario' : 'btn-primario'}`} onClick={() => setBajaAbierta(true)}>
      <FileMinus2 size={18} aria-hidden="true" /> Pedir baja
    </button>
  );

  return (
    <div>
      <Encabezado
        volver={volver}
        titulo={`Fianza ${f.fianza}`}
        descripcion={nombre(f.cliente_nombre)}
        acciones={(
          <>
            <button className="btn btn-secundario" onClick={() => imprimirConstancia(f, esMarca)}>
              <Printer size={18} aria-hidden="true" /> Constancia
            </button>
            {puede('verAfianzados') && (
              <Link className="btn btn-secundario" to={`/afianzados/${f.cliente_id}`}>
                <UserSearch size={18} aria-hidden="true" /> Perfil del afianzado
              </Link>
            )}
            {puede('reportarIncumplimiento') && ['VIGENTE', 'POR_RENOVAR', 'EN_BAJA', 'VENCIDA'].includes(f.estado) && (
              <button className="btn btn-peligro" onClick={() => setReclamoAbierto(true)}>
                <AlertOctagon size={18} aria-hidden="true" /> Reportar incumplimiento
              </button>
            )}
            {renovarPrimero ? <>{botonBaja}{botonRenovar}</> : <>{botonRenovar}{botonBaja}</>}
          </>
        )}
      />

      <div className="row" style={{ marginBottom: '1.5rem' }}>
        <Estado mapa={ESTADO_POLIZA} valor={f.estado} />
        {bajaPendiente && <Estado texto="Baja pedida" tono="atencion" />}
        {f.estado === 'EN_BAJA' && f.fecha_cancelacion && <Estado texto={`Cancela el ${fecha(f.fecha_cancelacion)}`} tono="atencion" />}
        {f.movimiento && <span className={`chip-mov ${f.movimiento.toLowerCase()}`}>{MOVIMIENTO[f.movimiento].ayuda}</span>}
      </div>

      {/* La marca ve su lenguaje: distribuidor, sin codigos internos ni endosos de Fidelis. */}
      <Datos items={[
        [esMarca ? 'Distribuidor' : 'Afianzado', nombre(f.cliente_nombre)],
        esMarca ? null : ['Código del afianzado', f.cliente_codigo],
        ['Beneficiario', nombre(f.beneficiario_nombre)],
        ['Marca', f.marca_nombre],
        ['Monto afianzado', <span key="monto" className="num">{q(f.monto_original)}</span>],
        ['Vigencia', `${fecha(f.vigencia_desde)} al ${fecha(f.vigencia_hasta)}`],
        ['Emitida', fecha(f.fecha_emision)],
        esMarca ? null : ['Endoso', f.endoso],
        ['Prima', <span key="prima" className="num">{q(f.prima)}</span>],
        ['Derechos e IVA', <span key="derechos" className="num">{q(Number(f.derechos) + Number(f.iva))}</span>],
        ['Contrato', f.contrato_numero],
        f.fecha_cancelacion ? ['Fecha de baja', fecha(f.fecha_cancelacion)] : null,
      ]} />

      <section className="seccion">
        <h2>Bajas</h2>
        {f.bajas?.length ? (
          <ul className="linea">
            {f.bajas.map((b) => (
              <li key={b.id}>
                <div className="row">
                  <strong>{b.numero_solicitud}</strong>
                  {canceladaEnFiso && ['PENDIENTE_REVISION', 'APROBADA'].includes(b.estado)
                    ? <Estado texto="Procesada en FISO" tono="ok" />
                    : <Estado mapa={ESTADO_BAJA} valor={b.estado} />}
                </div>
                <p className="small">{TIPO_BAJA[b.tipo_baja]}: {b.motivo}</p>
                {b.fecha_efectiva && (
                  <p className="small">
                    Fecha de cancelación: {fecha(b.fecha_efectiva)}
                  </p>
                )}
                {b.observaciones && <p className="small muted">Respuesta de Fidelis: {b.observaciones}</p>}
                <p className="small muted">{fechaHora(b.created_at)}</p>
              </li>
            ))}
          </ul>
        ) : <p className="muted">No hay solicitudes de baja para esta fianza.</p>}
      </section>

      {f.otrasPolizas?.length > 0 && (
        <section className="seccion">
          <h2>{esMarca ? 'Otras fianzas del mismo distribuidor' : 'Otras fianzas del mismo afianzado'}</h2>
          <div className="tabla-marco">
            <table className="tabla">
              <thead><tr><th>Fianza</th><th>Beneficiario</th><th>Vigencia</th><th>Estado</th><th className="derecha">Monto</th></tr></thead>
              <tbody>
                {f.otrasPolizas.map((o) => (
                  <tr key={o.id}>
                    <td><Link className="principal-celda num" to={`/cartera/${o.id}`}>{o.fianza}</Link></td>
                    <td className="small">{nombre(o.beneficiario_nombre)}</td>
                    <td className="small num">{fecha(o.vigencia_desde)} al {fecha(o.vigencia_hasta)}</td>
                    <td><Estado mapa={ESTADO_POLIZA} valor={o.estado} /></td>
                    <td className="derecha num">{q(o.monto_afianzado)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {bajaAbierta && <SolicitarBaja fianza={f} onCerrar={() => { setBajaAbierta(false); refetch(); }} />}
      {reclamoAbierto && <ReportarIncumplimiento fianza={f} onCerrar={() => setReclamoAbierto(false)} />}
    </div>
  );
}
