import { Link, useSearchParams } from 'react-router-dom';
import { ExternalLink } from 'lucide-react';
import { useAuth } from '../auth/AuthProvider';
import { Cargando, Encabezado, ErrorCarga, Estado, Pestanas, Vacio } from '../components/ui';
import { useToast } from '../components/ui/Toasts';
import { abrirDocumento } from '../data/altas';
import { useBajas } from '../data/bajas';
import { ESTADO_BAJA, TIPO_BAJA, procesadaEnFiso } from '../domain/estados';
import { fecha, nombre, q } from '../lib/format';

// La marca pide la baja. Queda procesada cuando FISO cancela la fianza: nadie la aprueba aqui.
const PESTANAS = [
  { valor: 'PEDIDAS', texto: 'Pendientes en FISO' },
  { valor: 'PROCESADAS', texto: 'Procesadas en FISO' },
  { valor: 'TODAS', texto: 'Todas' },
];
const FILTRO = { PEDIDAS: false, PROCESADAS: true, TODAS: null };

export default function Bajas() {
  const { usuario } = useAuth();
  const [params, setParams] = useSearchParams();
  const estado = FILTRO[params.get('estado')] !== undefined ? params.get('estado') : 'PEDIDAS';
  const { data, isLoading, error, refetch } = useBajas({ procesadas: FILTRO[estado] });
  const toast = useToast();

  return (
    <div>
      <Encabezado
        titulo="Bajas"
        descripcion={usuario.esMarca
          ? 'Para pedir una baja, abra la fianza en su cartera y use Pedir baja. Queda procesada cuando FISO cancela la fianza.'
          : 'Bajas que pidieron las marcas. Cada una surte efecto al cierre del mes elegido y queda procesada cuando FISO cancela la fianza.'}
        acciones={usuario.esMarca && <Link className="btn btn-secundario" to="/cartera?estado=ACTIVAS">Ir a mi cartera</Link>}
      />
      <Pestanas valor={estado} onCambiar={(v) => setParams({ estado: v }, { replace: true })} opciones={PESTANAS} />
      {isLoading && <Cargando />}
      {error && <ErrorCarga error={error} reintentar={refetch} />}
      {!isLoading && !error && !data?.length && <Vacio titulo="No hay bajas en esta pestaña" />}
      {data?.length > 0 && (
        <div className="tabla-marco">
          <table className="tabla">
            <thead>
              <tr><th>Fianza</th><th>Motivo</th><th>Pedida</th><th>Cancela</th><th>Situación</th><th className="derecha">Monto</th></tr>
            </thead>
            <tbody>
              {data.map((b) => (
                <tr key={b.id}>
                  <td>
                    <Link className="principal-celda num" to={`/cartera/${b.fianza?.id}`}>{b.fianza?.fianza}</Link>
                    <span className="secundaria-celda">{nombre(b.fianza?.cliente?.nombre)}</span>
                    {!usuario.esMarca && <span className="secundaria-celda">{nombre(b.fianza?.beneficiario?.nombre)}</span>}
                  </td>
                  <td className="small" style={{ maxWidth: 360 }}>
                    <strong>{TIPO_BAJA[b.tipo_baja]}</strong>. {b.motivo}
                    {b.observaciones && <span className="secundaria-celda">Fidelis: {b.observaciones}</span>}
                    {b.documentos?.map((d) => (
                      <button key={d.id} className="btn btn-texto btn-sm" style={{ paddingLeft: 0 }} onClick={() => abrirDocumento(d.file_path).catch(toast.error)}>
                        <ExternalLink size={14} aria-hidden="true" /> {d.nombre_archivo}
                      </button>
                    ))}
                  </td>
                  <td className="small num">{fecha(b.created_at)}<span className="secundaria-celda">{b.numero_solicitud}</span></td>
                  <td className="small num">{fecha(b.fecha_efectiva)}</td>
                  <td>
                    {procesadaEnFiso(b)
                      ? <Estado texto="Procesada en FISO" tono="ok" />
                      : <Estado mapa={ESTADO_BAJA} valor={b.estado} />}
                    {procesadaEnFiso(b) && b.fianza?.fecha_cancelacion && (
                      <span className="secundaria-celda">Cancelada el {fecha(b.fianza.fecha_cancelacion)}</span>
                    )}
                  </td>
                  <td className="derecha num">{q(b.fianza?.monto_afianzado)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
