import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Aviso, Campo, Modal } from './ui';
import { useReportarIncumplimiento } from '../data/reclamos';
import { TIPO_RECLAMO } from '../domain/estados';
import { fecha, hoyISO, nombre, q } from '../lib/format';
import { mensajeError } from '../lib/errores';

// La marca avisa que el distribuidor incumplio. Puede quedar como aviso (alerta temprana
// para que Fidelis gestione) o presentarse de una vez como reclamo formal.
export default function ReportarIncumplimiento({ fianza, onCerrar }) {
  const reportar = useReportarIncumplimiento();
  const navegar = useNavigate();
  const maximo = Number(fianza.monto_original || fianza.monto_afianzado || 0);
  const [d, setD] = useState({ tipo: 'FALTA_PAGO', fecha: hoyISO(), monto: '', unidades: '', descripcion: '', presentar: false });
  const [archivos, setArchivos] = useState([]);
  const [error, setError] = useState('');
  const set = (c) => (e) => setD((x) => ({ ...x, [c]: e.target.type === 'checkbox' ? e.target.checked : e.target.value }));

  async function enviar() {
    setError('');
    if (!(Number(d.monto) > 0)) return setError('Indique el monto adeudado o el valor de las unidades.');
    if (Number(d.monto) > maximo) return setError(`El monto no puede superar lo afianzado (${q(maximo)}).`);
    if (!d.descripcion.trim()) return setError('Describa qué pasó.');
    if (archivos.some((a) => a.size > 15 * 1024 * 1024)) return setError('Cada archivo debe pesar menos de 15 MB.');
    try {
      const r = await reportar.mutateAsync({ fianzaId: fianza.id, ...d, archivos });
      onCerrar();
      navegar(`/reclamos/${r.reclamo_id}`);
    } catch (e) {
      setError(mensajeError(e));
    }
  }

  return (
    <Modal
      ancho
      titulo="Reportar incumplimiento"
      subtitulo={`Fianza ${fianza.fianza} · ${nombre(fianza.cliente_nombre)} · afianzado por ${q(maximo)}`}
      onCerrar={onCerrar}
      pie={(
        <>
          <button className="btn btn-secundario" onClick={onCerrar}>Cancelar</button>
          <button className="btn btn-primario" onClick={enviar} disabled={reportar.isPending}>
            {reportar.isPending ? 'Enviando' : d.presentar ? 'Presentar reclamo' : 'Enviar aviso'}
          </button>
        </>
      )}
    >
      <div className="stack">
        {error && <Aviso tono="critico">{error}</Aviso>}
        <div className="grid-3">
          <Campo label="Qué pasó">
            {(p) => (
              <select {...p} className="control" value={d.tipo} onChange={set('tipo')}>
                {Object.entries(TIPO_RECLAMO).map(([v, t]) => <option key={v} value={v}>{t}</option>)}
              </select>
            )}
          </Campo>
          <Campo label="Fecha del incumplimiento" ayuda={`Dentro de la vigencia: ${fecha(fianza.vigencia_desde)} al ${fecha(fianza.vigencia_hasta)}.`}>
            {(p) => <input {...p} className="control" type="date" max={hoyISO()} value={d.fecha} onChange={set('fecha')} />}
          </Campo>
          <Campo label="Monto adeudado (Q)">
            {(p) => <input {...p} className="control" inputMode="decimal" value={d.monto} onChange={set('monto')} />}
          </Campo>
          <Campo label="Unidades involucradas" opcional>
            {(p) => <input {...p} className="control" inputMode="numeric" value={d.unidades} onChange={set('unidades')} />}
          </Campo>
        </div>
        <Campo label="Detalle" ayuda="Unidades, modelos o series, facturas pendientes y gestiones de cobro hechas con el distribuidor.">
          {(p) => <textarea {...p} className="control" value={d.descripcion} onChange={set('descripcion')} />}
        </Campo>
        <Campo label="Evidencia" opcional ayuda="Estado de cuenta del distribuidor, inventario, requerimientos de pago. PDF o imagen, 15 MB cada uno.">
          {(p) => <input {...p} type="file" multiple accept="application/pdf,image/png,image/jpeg" onChange={(e) => setArchivos([...(e.target.files || [])])} />}
        </Campo>
        <label className="check">
          <input type="checkbox" checked={d.presentar} onChange={set('presentar')} />
          <span>
            <strong>Presentar como reclamo formal.</strong> Si no lo marca, queda como aviso para que Fidelis gestione el
            cobro con el distribuidor.
          </span>
        </label>
      </div>
    </Modal>
  );
}
