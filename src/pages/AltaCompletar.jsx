import { useCallback } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';
import { Aviso, Cargando, Encabezado, ErrorCarga } from '../components/ui';
import FormularioExpediente, { Documentos } from '../components/expediente/FormularioExpediente';
import { guardarBorradorAlta, useAltaCompartida, useQuitarDocumentoAlta, useSubirDocumentoAlta } from '../data/altas';
import { nombre, q } from '../lib/format';

// La marca adelanta datos y documentos. Aceptar la declaracion y enviar sigue siendo del
// distribuidor desde su enlace. Despues del envio la marca corrige el formulario enviado hasta
// que la fianza se emite en FISO. Cada cambio queda en el registro con su nombre.
export default function AltaCompletar() {
  const { id } = useParams();
  const { data: a, isLoading, error, refetch } = useAltaCompartida(id);
  const subir = useSubirDocumentoAlta(id);
  const quitar = useQuitarDocumentoAlta(id);
  const guardar = useCallback((cambios) => guardarBorradorAlta(id, cambios), [id]);
  const volver = <Link to={`/altas/${id}`} className="volver"><ArrowLeft size={16} aria-hidden="true" /> Solicitud</Link>;

  if (isLoading) return <Cargando />;
  if (error) return <>{volver}<ErrorCarga error={error} reintentar={refetch} /></>;
  if (!a.editable && a.recibe_documentos) {
    return (
      <div style={{ maxWidth: 900 }}>
        <Encabezado volver={volver} titulo={`Documentos de ${nombre(a.afianzado)}`} descripcion={`${a.numero_solicitud} · ${q(a.monto_solicitado)}`} />
        <p className="muted" style={{ marginBottom: '1rem' }}>
          La solicitud ya está con Fidelis. Suba aquí lo que quedó pendiente y queda en el expediente de inmediato.
        </p>
        <Documentos requisitos={a.requisitos} modo="marca" subir={(x) => subir.mutateAsync(x)}
          quitar={(docId) => quitar.mutateAsync(docId)} onCambio={refetch} />
      </div>
    );
  }
  if (!a.editable) {
    return (
      <>
        {volver}
        <Aviso tono="info" titulo="Esta solicitud ya no admite cambios">La fianza ya se emitió en FISO o la solicitud es anterior al portal. Puede ver el estado en la solicitud.</Aviso>
      </>
    );
  }

  return (
    <div style={{ maxWidth: 900 }}>
      <Encabezado
        volver={volver}
        titulo={`${a.enviado ? 'Corregir datos' : 'Adelantar datos'} de ${nombre(a.afianzado)}`}
        descripcion={`${a.numero_solicitud} · ${q(a.monto_solicitado)}`}
      />
      <FormularioExpediente
        tipoPersona={a.tipo_persona}
        borrador={a.borrador}
        requisitos={a.requisitos}
        modo="marca"
        enviado={a.enviado}
        guardar={guardar}
        subir={(x) => subir.mutateAsync(x)}
        quitar={(docId) => quitar.mutateAsync(docId)}
        onCambioDocumentos={refetch}
        aviso={a.enviado ? (
          <div style={{ marginBottom: '1rem' }}>
            <Aviso tono="info" titulo="Puede corregir los datos hasta que la fianza se emita en FISO. Cada cambio queda registrado con su nombre.">
              El distribuidor ya envió su formulario. Lo que corrija se guarda solo y queda en el expediente, con el valor anterior.
            </Aviso>
          </div>
        ) : (
          <p className="small muted" style={{ margin: '0 0 1rem' }}>
            Llene lo que sepa y suba lo que tenga. Se guarda solo y el distribuidor lo ve en su enlace. Él solo revisa, completa lo que falte y envía.
          </p>
        )}
      />
    </div>
  );
}
