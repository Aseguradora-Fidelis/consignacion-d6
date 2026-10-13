import { useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { Plus } from 'lucide-react';
import { useAuth } from '../auth/AuthProvider';
import { Cargando, Encabezado, ErrorCarga, Estado, Pestanas, Vacio } from '../components/ui';
import { useAltas } from '../data/altas';
import { ESTADO_ALTA, ESTADOS_ANTERIORES, SIGUIENTE_PASO_MARCA } from '../domain/estados';
import { fecha, hace, nombre, q } from '../lib/format';
import { useDebounce } from '../lib/useDebounce';

// Las solicitudes avanzan solas: el distribuidor llena, Fidelis recibe y FISO emite.
const GRUPOS_PERSONAL = {
  RECIBIDAS: { texto: 'Recibidas', estados: ['EXPEDIENTE_RECIBIDO'] },
  LLENANDO: { texto: 'El distribuidor está llenando', estados: ['BORRADOR', 'IVE_PENDIENTE'] },
  EMITIDAS: { texto: 'Emitidas en FISO', estados: ['EMITIDA'] },
  ANTERIORES: { texto: 'Anteriores', estados: ESTADOS_ANTERIORES },
};

const GRUPOS_MARCA = {
  EN_TRAMITE: { texto: 'En trámite', estados: ['BORRADOR', 'IVE_PENDIENTE', 'EXPEDIENTE_RECIBIDO'] },
  EMITIDAS: { texto: 'Emitidas en FISO', estados: ['EMITIDA'] },
  ANTERIORES: { texto: 'Anteriores', estados: ESTADOS_ANTERIORES },
};

function TablaPersonal({ filas }) {
  const navegar = useNavigate();
  return (
    <div className="tabla-marco">
      <table className="tabla">
        <thead>
          <tr>
            <th>Distribuidor</th>
            <th>Marca</th>
            <th>Estado</th>
            <th>Documentos</th>
            <th>Notas</th>
            <th className="derecha">Monto</th>
          </tr>
        </thead>
        <tbody>
          {filas.map((a) => (
            <tr key={a.id} className="clic" onClick={() => navegar(`/altas/${a.id}`)}>
              <td>
                <Link className="principal-celda" to={`/altas/${a.id}`} onClick={(e) => e.stopPropagation()}>{nombre(a.afianzado_nombre)}</Link>
                <span className="secundaria-celda">{a.numero_solicitud} · {a.tipo_persona === 'JURIDICA' ? 'Sociedad' : 'Individual'} · {hace(a.ultimo_cambio || a.created_at)}</span>
              </td>
              <td className="small">{nombre(a.beneficiario_nombre)}</td>
              <td><Estado mapa={ESTADO_ALTA} valor={a.estado_operativo} /></td>
              <td className="small">{a.documentos_faltantes > 0 ? `Faltan ${a.documentos_faltantes}` : 'Completos'}</td>
              <td>
                <div className="row" style={{ gap: '0.35rem' }}>
                  {a.es_pep && <Estado texto="PEP" tono="critico" />}
                  {a.resolucion_vence && new Date(`${a.resolucion_vence}T00:00:00`) < new Date() && a.estado_operativo !== 'EMITIDA' && (
                    <Estado texto="Resolución vencida" tono="atencion" />
                  )}
                </div>
              </td>
              <td className="derecha num">
                {q(a.monto_aprobado || a.monto_solicitado)}
                {a.marcas_con_poliza > 0 && <span className="secundaria-celda">Ya afianzado: {q(a.exposicion_actual)}</span>}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function TablaMarca({ filas }) {
  const navegar = useNavigate();
  return (
    <div className="tabla-marco">
      <table className="tabla">
        <thead>
          <tr><th>Distribuidor</th><th>Estado</th><th>Qué está pasando</th><th className="derecha">Monto</th></tr>
        </thead>
        <tbody>
          {filas.map((a) => {
            const faltan = Array.isArray(a.faltantes) ? a.faltantes.length : 0;
            return (
              <tr key={a.id} className="clic" onClick={() => navegar(`/altas/${a.id}`)}>
                <td>
                  <Link className="principal-celda" to={`/altas/${a.id}`} onClick={(e) => e.stopPropagation()}>{nombre(a.afianzado_nombre)}</Link>
                  <span className="secundaria-celda">{a.numero_solicitud} · pedida el {fecha(a.created_at)}</span>
                </td>
                <td>
                  <Estado mapa={ESTADO_ALTA} valor={a.estado_operativo} />
                  {a.fianza_emitida && <span className="secundaria-celda">Fianza {a.fianza_emitida}</span>}
                </td>
                <td className="small">
                  {SIGUIENTE_PASO_MARCA[a.estado_operativo] || 'Solicitud anterior al portal.'}
                  {a.estado_operativo === 'EXPEDIENTE_RECIBIDO' && faltan > 0 && (
                    <span className="secundaria-celda">Faltan {faltan === 1 ? 'un documento' : `${faltan} documentos`}</span>
                  )}
                </td>
                <td className="derecha num">{q(a.monto_aprobado || a.monto_solicitado)}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export default function Altas() {
  const { usuario, puede } = useAuth();
  const esPersonal = puede('verExpedientes');
  const [params, setParams] = useSearchParams();
  const grupos = esPersonal ? GRUPOS_PERSONAL : GRUPOS_MARCA;
  const pestana = grupos[params.get('estado')] ? params.get('estado') : Object.keys(grupos)[0];
  const [buscar, setBuscar] = useState('');
  const buscarDiferido = useDebounce(buscar);
  const { data, isLoading, error, refetch } = useAltas({ esPersonal, buscar: buscarDiferido });

  const conteos = useMemo(() => {
    const c = {};
    for (const [k, g] of Object.entries(grupos)) c[k] = (data || []).filter((a) => g.estados.includes(a.estado_operativo)).length;
    return c;
  }, [data, grupos]);

  const filas = (data || []).filter((a) => grupos[pestana].estados.includes(a.estado_operativo));
  if (esPersonal && pestana === 'RECIBIDAS') {
    // Lo mas antiguo primero: es lo que lleva mas tiempo sin fianza en FISO.
    filas.sort((a, b) => new Date(a.ive_completed_at || a.created_at) - new Date(b.ive_completed_at || b.created_at));
  }
  // La pestana de solicitudes anteriores solo aparece si hay alguna.
  const opciones = Object.entries(grupos)
    .filter(([valor]) => valor !== 'ANTERIORES' || conteos.ANTERIORES > 0 || pestana === 'ANTERIORES')
    .map(([valor, g]) => ({ valor, texto: g.texto, contador: data ? conteos[valor] : null }));

  return (
    <div>
      <Encabezado
        titulo={esPersonal ? 'Solicitudes de alta' : 'Altas'}
        descripcion={esPersonal
          ? 'Cada solicitud con su expediente completo, para consultar. La emisión se hace en FISO y aquí aparece sola.'
          : `Solicitudes de fianza de ${usuario.marcas.map((m) => m.nombre).join(', ') || 'su marca'}.`}
        acciones={puede('solicitarAlta') && (
          <Link className="btn btn-primario" to="/altas/nueva"><Plus size={18} aria-hidden="true" /> Solicitar alta</Link>
        )}
      />
      <Pestanas valor={pestana} onCambiar={(v) => setParams({ estado: v }, { replace: true })} opciones={opciones} />
      <div className="filtros">
        <input
          className="control buscar"
          placeholder="Buscar por distribuidor o número de solicitud"
          aria-label="Buscar solicitudes"
          value={buscar}
          onChange={(e) => setBuscar(e.target.value)}
        />
      </div>
      {isLoading && <Cargando />}
      {error && <ErrorCarga error={error} reintentar={refetch} />}
      {!isLoading && !error && filas.length === 0 && (
        <Vacio titulo="No hay solicitudes en esta pestaña" />
      )}
      {filas.length > 0 && (esPersonal ? <TablaPersonal filas={filas} /> : <TablaMarca filas={filas} />)}
    </div>
  );
}
