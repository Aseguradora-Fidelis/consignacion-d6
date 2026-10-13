import { useState } from 'react';
import { UserPlus } from 'lucide-react';
import { useAuth } from '../auth/AuthProvider';
import { ROLES } from '../auth/permisos';
import { Aviso, Campo, Cargando, Encabezado, ErrorCarga, Estado, Modal, Paginacion, Pestanas } from '../components/ui';
import { useToast } from '../components/ui/Toasts';
import {
  useActivarUsuario, useAsignarBeneficiario, useAuditoria, useBeneficiariosSinMarca, useGuardarAccesos, useGuardarMarca,
  useInvitarUsuario, useReglasYTarifas, useUsuarios,
} from '../data/admin';
import { useMarcas } from '../data/cartera';
import { fechaHora } from '../lib/format';
import { mensajeError } from '../lib/errores';

const ROLES_PERSONAL = ['admin', 'suscripcion', 'comercial', 'coordinacion_comercial', 'cobros', 'contabilidad', 'consulta'];

function Accesos({ roles, grupos, onRoles, onGrupos, marcas }) {
  const esMarca = roles.includes('beneficiario');
  return (
    <div className="stack">
      <fieldset style={{ border: 0, padding: 0, margin: 0 }}>
        <legend className="etiqueta" style={{ fontWeight: 500, marginBottom: '0.5rem' }}>Tipo de usuario</legend>
        <div className="opciones">
          <label className="opcion">
            <input type="radio" checked={!esMarca} onChange={() => { onRoles([]); onGrupos([]); }} /> Personal de Fidelis
          </label>
          <label className="opcion">
            <input type="radio" checked={esMarca} onChange={() => onRoles(['beneficiario'])} /> Usuario de una marca
          </label>
        </div>
      </fieldset>
      {!esMarca ? (
        <fieldset style={{ border: 0, padding: 0, margin: 0 }}>
          <legend className="etiqueta" style={{ fontWeight: 500, marginBottom: '0.5rem' }}>Roles</legend>
          <div className="grid-2" style={{ gap: '0.5rem 1rem' }}>
            {ROLES_PERSONAL.map((r) => (
              <label key={r} className="check">
                <input type="checkbox" checked={roles.includes(r)}
                  onChange={(e) => onRoles(e.target.checked ? [...roles, r] : roles.filter((x) => x !== r))} />
                {ROLES[r]}
              </label>
            ))}
          </div>
        </fieldset>
      ) : (
        <fieldset style={{ border: 0, padding: 0, margin: 0 }}>
          <legend className="etiqueta" style={{ fontWeight: 500, marginBottom: '0.5rem' }}>Marca del usuario</legend>
          <div className="stack" style={{ gap: '0.4rem' }}>
            {(marcas || []).filter((m) => m.codigo !== 'GRP-GENERAL').map((m) => (
              <label key={m.id} className="check">
                <input type="radio" name="marca-usuario" checked={grupos[0] === m.id} onChange={() => onGrupos([m.id])} />
                {m.nombre}
              </label>
            ))}
          </div>
          <p className="small muted" style={{ marginTop: '0.5rem' }}>
            Cada usuario pertenece a una sola marca y nunca ve la cartera de otra. Si una persona trabaja con dos marcas, necesita un usuario para cada una.
          </p>
        </fieldset>
      )}
    </div>
  );
}

function EditarUsuario({ usuario, marcas, onCerrar }) {
  const guardar = useGuardarAccesos();
  const toast = useToast();
  const [roles, setRoles] = useState(usuario.roles);
  const [grupos, setGrupos] = useState(usuario.grupos);
  return (
    <Modal titulo={usuario.full_name} subtitulo={usuario.email} onCerrar={onCerrar}
      pie={(
        <>
          <button className="btn btn-secundario" onClick={onCerrar}>Cancelar</button>
          <button className="btn btn-primario" disabled={guardar.isPending}
            onClick={() => guardar.mutateAsync({ userId: usuario.id, roles, grupos, rolesAntes: usuario.roles, gruposAntes: usuario.grupos })
              .then(() => { toast.ok('Accesos actualizados.'); onCerrar(); }).catch(toast.error)}>
            Guardar
          </button>
        </>
      )}>
      <Accesos roles={roles} grupos={grupos} onRoles={setRoles} onGrupos={setGrupos} marcas={marcas} />
    </Modal>
  );
}

function Invitar({ marcas, onCerrar }) {
  const invitar = useInvitarUsuario();
  const toast = useToast();
  const [email, setEmail] = useState('');
  const [nombre, setNombre] = useState('');
  const [roles, setRoles] = useState(['beneficiario']);
  const [grupos, setGrupos] = useState([]);
  const [error, setError] = useState('');

  async function enviar() {
    setError('');
    try {
      await invitar.mutateAsync({ email: email.trim(), nombre: nombre.trim(), roles, grupos });
      toast.ok(`Invitación enviada a ${email}.`);
      onCerrar();
    } catch (e) {
      setError(mensajeError(e));
    }
  }

  return (
    <Modal titulo="Invitar usuario" onCerrar={onCerrar}
      pie={(
        <>
          <button className="btn btn-secundario" onClick={onCerrar}>Cancelar</button>
          <button className="btn btn-primario" onClick={enviar}
            disabled={invitar.isPending || !email.includes('@') || !nombre.trim() || (!roles.length) || (roles.includes('beneficiario') && !grupos.length)}>
            Enviar invitación
          </button>
        </>
      )}>
      <div className="stack">
        {error && <Aviso tono="critico">{error}</Aviso>}
        <div className="grid-2">
          <Campo label="Nombre">{(p) => <input {...p} className="control" value={nombre} onChange={(e) => setNombre(e.target.value)} />}</Campo>
          <Campo label="Correo">{(p) => <input {...p} className="control" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />}</Campo>
        </div>
        <Accesos roles={roles} grupos={grupos} onRoles={setRoles} onGrupos={setGrupos} marcas={marcas} />
        <p className="small muted">La persona recibe un correo para crear su contraseña.</p>
      </div>
    </Modal>
  );
}

function CambiarEstado({ usuario, onCerrar }) {
  const activar = useActivarUsuario();
  const toast = useToast();
  const desactivar = usuario.activo !== false;
  return (
    <Modal titulo={desactivar ? 'Desactivar usuario' : 'Reactivar usuario'} subtitulo={`${usuario.full_name} · ${usuario.email}`} onCerrar={onCerrar}
      pie={(
        <>
          <button className="btn btn-secundario" onClick={onCerrar}>Cancelar</button>
          <button className={`btn ${desactivar ? 'btn-peligro' : 'btn-primario'}`} disabled={activar.isPending}
            onClick={() => activar.mutateAsync({ userId: usuario.id, activo: !desactivar })
              .then(() => { toast.ok(desactivar ? 'Usuario desactivado.' : 'Usuario reactivado.'); onCerrar(); }).catch(toast.error)}>
            {desactivar ? 'Desactivar' : 'Reactivar'}
          </button>
        </>
      )}>
      <p>
        {desactivar
          ? 'Deja de entrar a la app y pierde sus permisos de inmediato. Su nombre se conserva en la bitácora y en las decisiones que tomó. Se puede reactivar después.'
          : 'Vuelve a entrar con los mismos roles y marcas que tenía.'}
      </p>
    </Modal>
  );
}

function Usuarios() {
  const { usuario: yo } = useAuth();
  const { data, isLoading, error, refetch } = useUsuarios();
  const marcas = useMarcas();
  const [editando, setEditando] = useState(null);
  const [cambiandoEstado, setCambiandoEstado] = useState(null);
  const [invitando, setInvitando] = useState(false);
  const nombreMarca = (id) => marcas.data?.find((m) => m.id === id)?.nombre || '';

  if (isLoading) return <Cargando />;
  if (error) return <ErrorCarga error={error} reintentar={refetch} />;
  return (
    <>
      <div className="row-between" style={{ marginBottom: '1rem' }}>
        <p className="muted">{data.length} usuarios · {data.filter((u) => u.activo === false).length} desactivados</p>
        <button className="btn btn-primario" onClick={() => setInvitando(true)}><UserPlus size={16} aria-hidden="true" /> Invitar usuario</button>
      </div>
      <div className="tabla-marco">
        <table className="tabla">
          <thead><tr><th>Usuario</th><th>Acceso</th><th>Estado</th><th>Alta</th><th /></tr></thead>
          <tbody>
            {data.map((u) => (
              <tr key={u.id}>
                <td><span className="principal-celda">{u.full_name}</span><span className="secundaria-celda">{u.email}</span></td>
                <td className="small">
                  {u.roles.includes('beneficiario')
                    ? `Marca: ${u.grupos.map(nombreMarca).join(', ') || 'sin marca asignada'}`
                    : u.roles.map((r) => ROLES[r]).join(', ') || <Estado texto="Sin acceso" tono="atencion" />}
                </td>
                <td className="small">
                  {u.activo === false
                    ? <><Estado texto="Desactivado" tono="neutro" />{u.desactivado_at && <span className="secundaria-celda num">{fechaHora(u.desactivado_at)}</span>}</>
                    : <Estado texto="Activo" tono="ok" />}
                </td>
                <td className="small num">{fechaHora(u.created_at)}</td>
                <td className="derecha">
                  <span className="row" style={{ justifyContent: 'flex-end', gap: '0.35rem' }}>
                    <button className="btn btn-secundario btn-sm" onClick={() => setEditando(u)} disabled={u.id === yo.id || u.activo === false}
                      title={u.id === yo.id ? 'No puede cambiar sus propios accesos' : undefined}>
                      Editar accesos
                    </button>
                    <button className={`btn btn-sm ${u.activo === false ? 'btn-secundario' : 'btn-texto'}`} onClick={() => setCambiandoEstado(u)}
                      disabled={u.id === yo.id} title={u.id === yo.id ? 'No puede desactivarse a usted mismo' : undefined}>
                      {u.activo === false ? 'Reactivar' : 'Desactivar'}
                    </button>
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {editando && <EditarUsuario usuario={editando} marcas={marcas.data} onCerrar={() => setEditando(null)} />}
      {cambiandoEstado && <CambiarEstado usuario={cambiandoEstado} onCerrar={() => setCambiandoEstado(null)} />}
      {invitando && <Invitar marcas={marcas.data} onCerrar={() => setInvitando(false)} />}
    </>
  );
}

function SinMarca({ marcas }) {
  const { data } = useBeneficiariosSinMarca();
  const asignar = useAsignarBeneficiario();
  const toast = useToast();
  const [eleccion, setEleccion] = useState({});
  if (!data?.length) return null;
  return (
    <section className="seccion">
      <h2>Beneficiarios sin marca</h2>
      <Aviso tono="atencion">
        Llegaron en la cartera de Oracle y ninguna marca los ve. Asigne cada uno a su marca.
      </Aviso>
      <div className="tabla-marco" style={{ marginTop: '1rem' }}>
        <table className="tabla">
          <thead><tr><th>Beneficiario</th><th>Marca</th><th /></tr></thead>
          <tbody>
            {data.map((b) => (
              <tr key={b.id}>
                <td className="principal-celda">{b.nombre}<span className="secundaria-celda">Código {b.codigo_contacto}</span></td>
                <td>
                  <select className="control" value={eleccion[b.id] || ''} aria-label={`Marca de ${b.nombre}`}
                    onChange={(e) => setEleccion((x) => ({ ...x, [b.id]: e.target.value }))}>
                    <option value="">Elija</option>
                    {marcas.filter((m) => m.codigo !== 'GRP-GENERAL').map((m) => <option key={m.id} value={m.id}>{m.nombre}</option>)}
                  </select>
                </td>
                <td className="derecha">
                  <button className="btn btn-primario btn-sm" disabled={!eleccion[b.id] || asignar.isPending}
                    onClick={() => asignar.mutateAsync({ beneficiarioId: b.id, grupoId: eleccion[b.id] }).then(() => toast.ok('Beneficiario asignado.')).catch(toast.error)}>
                    Asignar
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function Marcas() {
  const { data, isLoading, error, refetch } = useReglasYTarifas();
  const guardar = useGuardarMarca();
  const toast = useToast();
  const [cambios, setCambios] = useState({});
  if (isLoading) return <Cargando />;
  if (error) return <ErrorCarga error={error} reintentar={refetch} />;
  return (
    <div className="stack">
      <p className="muted">Tarifa de prima anual y regla de cobro de cada marca. Se usan al calcular la prima y el vencimiento del estado de cuenta.</p>
      <div className="tabla-marco">
        <table className="tabla">
          <thead><tr><th>Marca</th><th>Tarifa anual (%)</th><th>Regla de cobro</th><th /></tr></thead>
          <tbody>
            {data.marcas.map((m) => {
              const c = cambios[m.id] || {};
              const tarifa = c.tarifa ?? (Number(m.tarifa_prima) * 100).toFixed(2);
              const regla = c.regla ?? (m.codigo_regla_cobro || '');
              return (
                <tr key={m.id}>
                  <td className="principal-celda">{m.nombre}<span className="secundaria-celda">{m.codigo}</span></td>
                  <td style={{ width: 160 }}>
                    <input className="control" inputMode="decimal" value={tarifa} aria-label={`Tarifa de ${m.nombre}`}
                      onChange={(e) => setCambios((x) => ({ ...x, [m.id]: { ...c, tarifa: e.target.value } }))} />
                  </td>
                  <td>
                    <select className="control" value={regla} aria-label={`Regla de cobro de ${m.nombre}`}
                      onChange={(e) => setCambios((x) => ({ ...x, [m.id]: { ...c, regla: e.target.value } }))}>
                      <option value="">General</option>
                      {data.reglas.map((r) => <option key={r.codigo_marca} value={r.codigo_marca}>{r.nombre || r.codigo_marca}</option>)}
                    </select>
                  </td>
                  <td className="derecha">
                    {cambios[m.id] && (
                      <button className="btn btn-primario btn-sm" disabled={guardar.isPending || !(Number(tarifa) > 0 && Number(tarifa) < 20)}
                        onClick={() => guardar.mutateAsync({ id: m.id, tarifa: Number(tarifa) / 100, regla })
                          .then(() => { setCambios((x) => { const y = { ...x }; delete y[m.id]; return y; }); toast.ok('Marca actualizada.'); })
                          .catch(toast.error)}>
                        Guardar
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <SinMarca marcas={data.marcas} />
    </div>
  );
}

const TABLAS = { fianzas: 'Fianzas', solicitudes_alta: 'Altas', solicitudes_baja: 'Bajas', pagos: 'Pagos' };
const ACCIONES = { INSERT: 'Creó', UPDATE: 'Modificó', DELETE: 'Borró' };
// Nombres de negocio para las columnas que cambian con mas frecuencia.
const COLUMNAS = {
  estado_operativo: 'Estado', operational_status: 'Estado de la póliza', estado: 'Estado',
  monto_aprobado: 'Monto aprobado', monto_solicitado: 'Monto solicitado', monto_afianzado: 'Monto afianzado', monto: 'Monto',
  fecha_cancelacion: 'Fecha de baja', vigencia_desde: 'Vigente desde', vigencia_hasta: 'Vigente hasta',
  contrato_numero: 'Contrato', contrato_fecha: 'Fecha del contrato', condiciones_emision: 'Condiciones', contragarantia: 'Contragarantía',
  resolucion_comentario: 'Comentario de Suscripción', pago_confirmado_at: 'Pago confirmado', lote_fiso: 'Lote FISO',
  prima: 'Prima', referencia_bancaria: 'Boleta', observaciones: 'Observaciones', emitida_en: 'Emitida',
};
// Columnas tecnicas o con datos personales extensos: no aportan a la bitacora.
const OMITIR = /(_id|_at|^id|^estado$|ive_data|ive_borrador|analisis_suscripcion|faltantes|exposicion_vigente)$/;

function legible(v) {
  if (v === null || v === undefined || v === '') return 'vacío';
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(v)) return fechaHora(v);
  return String(v);
}

function cambiosDe(registro) {
  if (registro.action !== 'UPDATE') return [];
  const a = registro.old_data || {};
  const b = registro.new_data || {};
  return Object.keys(b)
    .filter((k) => (COLUMNAS[k] || !OMITIR.test(k)) && JSON.stringify(a[k]) !== JSON.stringify(b[k]))
    .filter((k) => !(k === 'estado' && 'estado_operativo' in b))
    .map((k) => `${COLUMNAS[k] || k}: ${legible(a[k])} → ${legible(b[k])}`);
}

function Auditoria() {
  const [pagina, setPagina] = useState(1);
  const [tabla, setTabla] = useState('');
  const { data, isLoading, error, refetch } = useAuditoria({ pagina, tabla });
  return (
    <div>
      <div className="filtros">
        <select className="control" value={tabla} onChange={(e) => { setTabla(e.target.value); setPagina(1); }} aria-label="Tabla">
          <option value="">Todos los registros</option>
          {Object.entries(TABLAS).map(([v, t]) => <option key={v} value={v}>{t}</option>)}
        </select>
      </div>
      {isLoading && <Cargando />}
      {error && <ErrorCarga error={error} reintentar={refetch} />}
      {data?.data && (
        <>
          <div className="tabla-marco">
            <table className="tabla">
              <thead><tr><th>Fecha</th><th>Quién</th><th>Qué</th><th>Cambios</th></tr></thead>
              <tbody>
                {data.data.map((r) => (
                  <tr key={r.id}>
                    <td className="small num">{fechaHora(r.created_at)}</td>
                    <td className="small">{r.autor?.full_name || r.performed_by_email || (r.origen === 'PORTAL' ? 'Distribuidor desde el portal' : r.origen === 'SISTEMA' ? 'Carga de Oracle' : 'Sistema o portal')}</td>
                    <td className="small">{ACCIONES[r.action]} {TABLAS[r.table_name]?.toLowerCase() || r.table_name}
                      <span className="secundaria-celda">{r.new_data?.numero_solicitud || r.new_data?.fianza || r.old_data?.numero_solicitud || ''}</span>
                    </td>
                    <td className="small" style={{ maxWidth: 480 }}>
                      {cambiosDe(r).slice(0, 5).map((c) => <span key={c} className="secundaria-celda" style={{ overflowWrap: 'anywhere' }}>{c}</span>)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <Paginacion pagina={pagina} porPagina={30} total={data.count} onCambiar={setPagina} />
        </>
      )}
    </div>
  );
}

export default function Admin() {
  const [pestana, setPestana] = useState('usuarios');
  return (
    <div>
      <Encabezado titulo="Administración" descripcion="Accesos de personal y marcas, tarifas y bitácora de cambios." />
      <Pestanas valor={pestana} onCambiar={setPestana} opciones={[
        { valor: 'usuarios', texto: 'Usuarios' },
        { valor: 'marcas', texto: 'Marcas y tarifas' },
        { valor: 'auditoria', texto: 'Bitácora' },
      ]} />
      {pestana === 'usuarios' && <Usuarios />}
      {pestana === 'marcas' && <Marcas />}
      {pestana === 'auditoria' && <Auditoria />}
    </div>
  );
}
