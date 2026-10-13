import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { Cargando, Encabezado, ErrorCarga, Estado, Kpi, Pestanas, Vacio } from '../components/ui';
import { useReclamos } from '../data/reclamos';
import { ESTADO_RECLAMO, TIPO_RECLAMO } from '../domain/estados';
import { fecha, hace, nombre, q } from '../lib/format';
import { AlertOctagon, HandCoins, Hourglass, Undo2 } from 'lucide-react';

const PESTANAS = [
  { valor: 'ABIERTOS', texto: 'Abiertos' },
  { valor: 'AVISO', texto: 'Avisos' },
  { valor: 'EN_RECOBRO', texto: 'En recobro' },
  { valor: 'CERRADOS', texto: 'Cerrados' },
];

export default function Reclamos() {
  const { usuario } = useAuth();
  const [params, setParams] = useSearchParams();
  const estado = params.get('estado') || 'ABIERTOS';
  const navegar = useNavigate();
  // En recobro es gestion de Fidelis con el distribuidor: la marca no ve esa pestana.
  const pestanas = usuario.esMarca ? PESTANAS.filter((p) => p.valor !== 'EN_RECOBRO') : PESTANAS;
  const estadoVisible = pestanas.some((p) => p.valor === estado) ? estado : 'ABIERTOS';
  const { data, isLoading, error, refetch } = useReclamos({ estado: estadoVisible });
  const todos = useReclamos({});

  const lista = todos.data || [];
  const abiertos = lista.filter((r) => !['IMPROCEDENTE', 'CERRADO', 'DESISTIDO', 'RECUPERADO'].includes(r.estado));
  const pagado = lista.reduce((t, r) => t + Number(r.monto_pagado || 0), 0);
  const recuperado = lista.reduce((t, r) => t + Number(r.monto_recuperado || 0), 0);

  return (
    <div>
      <Encabezado
        titulo="Reclamos"
        descripcion={usuario.esMarca
          ? 'Si un distribuidor no paga lo vendido o pierde unidades, repórtelo desde la fianza en su cartera.'
          : 'Avisos y reclamos que reportaron las marcas, con su evidencia y su seguimiento.'}
        acciones={usuario.esMarca && <Link className="btn btn-primario" to="/cartera?estado=ACTIVAS">Reportar desde mi cartera</Link>}
      />

      <div className="kpis" style={{ marginBottom: '1rem' }}>
        <Kpi destacado icono={AlertOctagon} pregunta="Reclamos abiertos" valor={abiertos.length}
          contexto={q(abiertos.reduce((t, r) => t + Number(r.monto_reclamado), 0)) + ' reclamado'} />
        <Kpi icono={Hourglass} pregunta="Avisos sin formalizar" valor={lista.filter((r) => r.estado === 'AVISO').length}
          contexto="Alerta temprana de la marca" to="/reclamos?estado=AVISO" />
        <Kpi icono={HandCoins} pregunta="Pagado a marcas" valor={q(pagado)} contexto="Reclamos procedentes" />
        {!usuario.esMarca && (
          <Kpi icono={Undo2} pregunta="Recuperado del afianzado" valor={q(recuperado)}
            contexto={pagado ? `${Math.round((recuperado / pagado) * 100)} % de lo pagado` : 'Sin pagos'} />
        )}
      </div>

      <Pestanas valor={estadoVisible} onCambiar={(v) => setParams({ estado: v }, { replace: true })} opciones={pestanas} />
      {isLoading && <Cargando />}
      {error && <ErrorCarga error={error} reintentar={refetch} />}
      {!isLoading && !error && !data?.length && <Vacio titulo="No hay reclamos en esta pestaña" />}
      {data?.length > 0 && (
        <div className="tabla-marco">
          <table className="tabla">
            <thead>
              <tr><th>Reclamo</th><th>{usuario.esMarca ? 'Distribuidor' : 'Afianzado'}</th>{!usuario.esMarca && <th>Marca</th>}<th>Motivo</th><th>Estado</th><th className="derecha">Reclamado</th></tr>
            </thead>
            <tbody>
              {data.map((r) => (
                <tr key={r.id} className="clic" onClick={() => navegar(`/reclamos/${r.id}`)}>
                  <td>
                    <Link className="principal-celda" to={`/reclamos/${r.id}`} onClick={(e) => e.stopPropagation()}>{r.numero}</Link>
                    <span className="secundaria-celda">Fianza {r.fianza} · {hace(r.ultimo_movimiento || r.created_at)}</span>
                  </td>
                  <td>{nombre(r.afianzado_nombre)}{!usuario.esMarca && <span className="secundaria-celda">Código {r.afianzado_codigo}</span>}</td>
                  {!usuario.esMarca && <td className="small">{nombre(r.beneficiario_nombre)}</td>}
                  <td className="small">{TIPO_RECLAMO[r.tipo]}<span className="secundaria-celda">desde {fecha(r.fecha_incumplimiento)}</span></td>
                  <td><Estado mapa={ESTADO_RECLAMO} valor={r.estado} /></td>
                  <td className="derecha num">
                    {q(r.monto_reclamado)}
                    {r.monto_pagado > 0 && <span className="secundaria-celda">pagado {q(r.monto_pagado)}</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
