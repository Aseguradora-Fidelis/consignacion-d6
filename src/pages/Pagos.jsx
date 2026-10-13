import { useMemo } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { Cargando, Encabezado, ErrorCarga, Estado, Kpi, Pestanas, Vacio } from '../components/ui';
import { useMarcas } from '../data/cartera';
import { resumirCuenta, useCuentaMarca } from '../data/cobros';
import { ESTADO_PAGO } from '../domain/estados';
import { fecha, fechaHora, mes, numero, q } from '../lib/format';

const PESTANAS = [
  { valor: 'PENDIENTES', texto: 'Con saldo' },
  { valor: 'PAGADO', texto: 'Pagados' },
  { valor: '', texto: 'Todos' },
];

// Lo que FISO le facturo a cada marca, por mes, con lo pagado y el saldo de la ultima carga.
// Solo de consulta: el aviso de cobro lo manda FISO y los pagos se aplican en FISO.
export default function Pagos() {
  const { usuario } = useAuth();
  const [params, setParams] = useSearchParams();
  const navegar = useNavigate();
  const pestana = params.get('estado') ?? 'PENDIENTES';
  const marcaId = params.get('marca') || '';
  const marcas = useMarcas();
  const { data, isLoading, error, refetch } = useCuentaMarca({ marcaId });
  const r = resumirCuenta(data);

  const filas = useMemo(() => (data || []).filter((f) => (
    pestana === 'PENDIENTES' ? f.estado !== 'PAGADO' : pestana ? f.estado === pestana : true
  )), [data, pestana]);

  const cambiar = (clave, valor) => {
    const p = new URLSearchParams(params);
    if (valor) p.set(clave, valor);
    else p.delete(clave);
    setParams(p, { replace: true });
  };

  return (
    <div>
      <Encabezado
        titulo={usuario.esMarca ? 'Pagos a Fidelis' : 'Cuenta de cada marca'}
        descripcion={usuario.esMarca
          ? 'Lo que Fidelis le facturó cada mes por sus fianzas de consignación, con lo pagado y el saldo.'
          : 'Lo que FISO le facturó a cada marca por mes, con lo pagado y el saldo. Los pagos se aplican en FISO.'}
      />

      {data && <div className="kpis" style={{ marginBottom: '2rem' }}>
        <Kpi destacado pregunta={usuario.esMarca ? '¿Cuánto debo?' : '¿Cuánto deben las marcas?'} valor={q(r.saldo)}
          contexto={r.saldoAl ? `Saldo según FISO al ${fechaHora(r.saldoAl)}` : 'Sin carga de facturas de FISO'}
          fuente="Facturas D-6 de FISO, con su saldo en la última carga" />
        <Kpi pregunta="¿Cuánto está vencido?" valor={q(r.vencido)}
          contexto={r.mesesVencidos ? `${numero(r.mesesVencidos)} ${r.mesesVencidos === 1 ? 'mes' : 'meses'} vencidos` : 'Nada vencido'} />
        <Kpi pregunta="Por pagar sin vencer" valor={q(r.porPagar)}
          contexto={r.mesesPorPagar ? `${numero(r.mesesPorPagar)} ${r.mesesPorPagar === 1 ? 'mes' : 'meses'}` : 'Nada pendiente'} />
      </div>}

      <Pestanas valor={pestana} onCambiar={(v) => cambiar('estado', v)} opciones={PESTANAS} />
      {!usuario.esMarca && (
        <div className="filtros">
          <select className="control" aria-label="Marca" value={marcaId} onChange={(e) => cambiar('marca', e.target.value)}>
            <option value="">Todas las marcas</option>
            {(marcas.data || []).map((m) => <option key={m.id} value={m.id}>{m.nombre}</option>)}
          </select>
        </div>
      )}

      {isLoading && <Cargando />}
      {error && <ErrorCarga error={error} reintentar={refetch} />}
      {!isLoading && !error && !filas.length && <Vacio titulo="No hay meses en esta pestaña" />}
      {filas.length > 0 && (
        <div className="tabla-marco">
          <table className="tabla">
            <thead>
              <tr>
                <th>Mes</th>
                {!usuario.esMarca && <th>Marca</th>}
                <th>Vence</th>
                <th>Situación</th>
                <th className="derecha">Total</th>
                <th className="derecha">Pagado</th>
                <th className="derecha">Saldo</th>
              </tr>
            </thead>
            <tbody>
              {filas.map((f) => {
                const ruta = `/pagos/${f.marca_id}/${f.periodo}`;
                return (
                  <tr key={`${f.marca_id}-${f.periodo}`} className="clic" onClick={() => navegar(ruta)}>
                    <td>
                      <Link className="principal-celda" to={ruta} onClick={(ev) => ev.stopPropagation()}>{mes(f.periodo)}</Link>
                      <span className="secundaria-celda">
                        {numero(f.facturas)} {Number(f.facturas) === 1 ? 'factura' : 'facturas'}{f.mes_en_curso ? ' · mes en curso' : ''}
                      </span>
                    </td>
                    {!usuario.esMarca && <td className="small">{f.marca_nombre}</td>}
                    <td className="num small">{fecha(f.vence)}</td>
                    <td>
                      <Estado mapa={ESTADO_PAGO} valor={f.estado} />
                      {f.dias_vencido > 0 && <span className="secundaria-celda" style={{ color: 'var(--critico)' }}>{numero(f.dias_vencido)} días vencido</span>}
                    </td>
                    <td className="derecha num">{q(f.total)}</td>
                    <td className="derecha num">{q(f.pagado)}</td>
                    <td className="derecha num"><strong>{q(f.saldo)}</strong></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {r.saldoAl && <p className="small muted" style={{ marginTop: '0.75rem' }}>Saldo según FISO al {fechaHora(r.saldoAl)}.</p>}
    </div>
  );
}
