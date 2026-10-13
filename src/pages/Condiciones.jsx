import { useAuth } from '../auth/AuthProvider';
import { Cargando, Datos, Encabezado, ErrorCarga, Panel, Vacio } from '../components/ui';
import { useCondicionesMarca } from '../data/operacion';
import { resumenCondiciones } from '../domain/condiciones';
import { fechaHora } from '../lib/format';

// Lo acordado con cada marca. Solo de consulta: se acuerda y se registra fuera de la app.
export default function Condiciones() {
  const { usuario } = useAuth();
  const { data, isLoading, error, refetch } = useCondicionesMarca();

  return (
    <div>
      <Encabezado
        titulo={usuario.esMarca ? 'Condiciones de su marca' : 'Condiciones por marca'}
        descripcion={usuario.esMarca
          ? 'Lo acordado entre su empresa y Fidelis para las fianzas de consignación.'
          : 'Lo acordado con cada marca para las fianzas de consignación.'}
      />
      {isLoading && <Cargando />}
      {error && <ErrorCarga error={error} reintentar={refetch} />}
      {data && !data.length && <Vacio titulo="No hay condiciones registradas" />}
      {data?.length > 0 && (
        <div className="tarjetas-marca">
          {data.map((c) => (
            <Panel key={c.id} titulo={c.grupo?.nombre} subtitulo={`Actualizado ${fechaHora(c.updated_at)}`}>
              <Datos items={resumenCondiciones(c)} />
              {c.notas && <p className="small" style={{ marginTop: '0.85rem' }}>{c.notas}</p>}
            </Panel>
          ))}
        </div>
      )}
    </div>
  );
}
