import { Encabezado } from '../components/ui';
import { TERMINOS } from '../domain/glosario';

export default function Glosario() {
  return (
    <div>
      <Encabezado titulo="Glosario" descripcion="Qué significa cada término de la fianza de consignación D-6, para que la marca, el afianzado y Fidelis hablen igual." />

      <section className="seccion">
        <h2>Términos</h2>
        <dl className="glosario">
          {TERMINOS.map(([t, d]) => (
            <div key={t}>
              <dt>{t}</dt>
              <dd>{d}</dd>
            </div>
          ))}
        </dl>
      </section>
    </div>
  );
}
