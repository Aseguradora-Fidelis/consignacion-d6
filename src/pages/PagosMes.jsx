import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Download, Printer } from 'lucide-react';
import { useAuth } from '../auth/AuthProvider';
import { Cargando, Datos, Encabezado, ErrorCarga, Estado, Vacio } from '../components/ui';
import { useToast } from '../components/ui/Toasts';
import { useMesCuenta } from '../data/cobros';
import { ESTADO_PAGO } from '../domain/estados';
import { fecha, fechaHora, mes, nombre, q } from '../lib/format';
import { esc } from '../lib/html';
import { descargarExcel } from '../lib/exportar';

// Una factura de FISO, o una nota de cobro si todavia no se factura.
function documento(f) {
  return f.factura
    ? { tipo: 'Factura', numero: `${f.serie ? `${f.serie}-` : ''}${f.factura}` }
    : { tipo: 'Nota de cobro', numero: String(f.correlativo_cobro) };
}

function imprimir(resumen, facturas, marcaNombre) {
  const v = window.open('', '_blank', 'width=1000,height=1000');
  if (!v) return;
  v.opener = null;
  const filas = facturas.map((f) => {
    const d = documento(f);
    return `<tr><td>${esc(d.tipo)} ${esc(d.numero)}</td><td>${esc(f.fianza)}</td><td>${esc(f.endoso)}</td><td>${esc(nombre(f.poliza?.cliente?.nombre))}</td>
    <td>${esc(fecha(f.fecha_emision))}</td><td class="n">${esc(q(f.total))}</td><td class="n">${esc(q(f.saldo))}</td></tr>`;
  }).join('');
  v.document.write(`<!doctype html><html lang="es"><head><meta charset="utf-8"><title>${esc(marcaNombre)} ${esc(mes(resumen.periodo))}</title>
<style>body{font-family:Roboto,Arial,sans-serif;color:#111;margin:40px;font-size:12px}img{height:48px}
h1{font-family:Poppins,Arial,sans-serif;font-size:20px;margin:24px 0 4px}table{width:100%;border-collapse:collapse;margin-top:20px}
th{text-align:left;color:#4a4a4a;font-weight:500;border-bottom:1px solid #ccc;padding:6px}td{padding:6px;border-bottom:1px solid #e0e0e0}
.n{text-align:right;white-space:nowrap}tfoot td{font-weight:700;border-top:2px solid #000}</style></head><body>
<img src="${esc(window.location.origin)}/brand/fidelis-fianzas.svg" alt="Fidelis Fianzas">
<h1>Facturación de ${esc(mes(resumen.periodo).toLowerCase())}</h1>
<p>${esc(marcaNombre)} · vence el ${esc(fecha(resumen.vence))}</p>
<table><thead><tr><th>Documento</th><th>Fianza</th><th>Endoso</th><th>Distribuidor</th><th>Fecha</th><th class="n">Total</th><th class="n">Saldo</th></tr></thead>
<tbody>${filas}</tbody><tfoot><tr><td colspan="5">Total</td><td class="n">${esc(q(resumen.total))}</td><td class="n">${esc(q(resumen.saldo))}</td></tr></tfoot></table>
<p style="margin-top:32px">Saldo según FISO al ${esc(fechaHora(resumen.saldo_fiso_al))}. Consultas al 2285 7000.</p>
<script>window.onload=function(){window.print()}</script></body></html>`);
  v.document.close();
}

export default function PagosMes() {
  const { marcaId, periodo } = useParams();
  const { usuario } = useAuth();
  const { data, isLoading, error, refetch } = useMesCuenta(marcaId, periodo);
  const toast = useToast();
  const volver = <Link to="/pagos" className="volver"><ArrowLeft size={16} aria-hidden="true" /> {usuario.esMarca ? 'Pagos a Fidelis' : 'Cuenta de cada marca'}</Link>;

  if (isLoading) return <Cargando />;
  if (error) return <>{volver}<ErrorCarga error={error} reintentar={refetch} /></>;
  if (!data?.resumen) return <>{volver}<Vacio titulo="No hay facturas de FISO en ese mes" /></>;
  const { resumen: r, facturas } = data;

  function excel() {
    descargarExcel(`${r.marca_nombre} ${periodo.slice(0, 7)}.xlsx`, 'Facturas', facturas.map((f) => {
      const d = documento(f);
      return {
        Documento: d.tipo, Numero: d.numero, Fianza: f.fianza, Endoso: f.endoso, Fecha: f.fecha_emision,
        Distribuidor: nombre(f.poliza?.cliente?.nombre), Beneficiario: nombre(f.beneficiario?.nombre),
        Prima: Number(f.prima), Derechos: Number(f.derechos), IVA: Number(f.iva), Otros: Number(f.otros || 0),
        Total: Number(f.total), Saldo: Number(f.saldo),
      };
    })).catch(toast.error);
  }

  return (
    <div>
      <Encabezado
        volver={volver}
        titulo={`Facturación de ${mes(r.periodo).toLowerCase()}`}
        descripcion={r.marca_nombre}
        acciones={(
          <>
            <button className="btn btn-secundario" onClick={excel}><Download size={16} aria-hidden="true" /> Excel</button>
            <button className="btn btn-secundario" onClick={() => imprimir(r, facturas, r.marca_nombre)}><Printer size={16} aria-hidden="true" /> Imprimir</button>
          </>
        )}
      />

      <div className="row" style={{ marginBottom: '1.5rem' }}>
        <Estado mapa={ESTADO_PAGO} valor={r.estado} />
        {r.mes_en_curso && <Estado texto="Mes en curso" tono="neutro" />}
      </div>

      <Datos items={[
        ['Total', <strong key="total" className="num">{q(r.total)}</strong>],
        ['Pagado', <span key="pagado" className="num">{q(r.pagado)}</span>],
        ['Saldo', <strong key="saldo" className="num">{q(r.saldo)}</strong>],
        ['Vence', fecha(r.vence)],
        r.dias_vencido > 0 ? ['Días vencido', r.dias_vencido] : null,
      ]} />
      <p className="small muted" style={{ marginTop: '0.75rem' }}>
        {r.saldo_fiso_al ? `Saldo según FISO al ${fechaHora(r.saldo_fiso_al)}.` : 'Todavía no llega el saldo de estas facturas en la carga de FISO.'}
      </p>

      <section className="seccion">
        <h2>Facturas y notas de cobro</h2>
        {facturas.length === 0 ? <p className="muted">FISO no le facturó D-6 a esta marca en ese mes.</p> : (
          <div className="tabla-marco">
            <table className="tabla">
              <thead>
                <tr>
                  <th>Documento</th><th>Fianza</th><th>Endoso</th><th>Fecha</th>
                  <th className="derecha">Total</th><th className="derecha">Saldo</th>
                </tr>
              </thead>
              <tbody>
                {facturas.map((f) => {
                  const d = documento(f);
                  return (
                    <tr key={f.correlativo_cobro}>
                      <td>{d.tipo} <span className="num">{d.numero}</span></td>
                      <td>
                        <span className="num">{f.poliza?.id ? <Link to={`/cartera/${f.poliza.id}`}>{f.fianza}</Link> : f.fianza}</span>
                        {f.poliza?.cliente?.nombre && <span className="secundaria-celda">{nombre(f.poliza.cliente.nombre)}</span>}
                      </td>
                      <td className="num">{f.endoso}</td>
                      <td className="num small">{fecha(f.fecha_emision)}</td>
                      <td className="derecha num">{q(f.total)}</td>
                      <td className="derecha num">
                        <strong>{q(f.saldo)}</strong>
                        {Number(f.saldo) <= 0 && f.fecha_pago && <span className="secundaria-celda">Pagada el {fecha(f.fecha_pago)}</span>}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
