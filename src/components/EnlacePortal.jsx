import { useState } from 'react';
import { Copy, Mail, MessageCircle } from 'lucide-react';
import { enlacePortal } from '../data/altas';
import { fechaHora, nombre } from '../lib/format';

// Muestra el enlace del portal para que la marca o Fidelis lo haga llegar al afianzado.
// El enlace solo existe en este momento: la base guarda el hash, no el token.
export default function EnlacePortal({ token, expira, afianzado, correo, telefono, marca }) {
  const [copiado, setCopiado] = useState(false);
  const url = enlacePortal(token);
  const mensaje = `Buen día ${nombre(afianzado)}. Para su fianza de consignación con ${nombre(marca)}, llene su formulario y suba sus `
    + `documentos en este enlace de Fidelis: ${url}\n\nTenga a mano fotos de su DPI, RTU, patente de comercio, un recibo de luz o agua `
    + `y sus estados de cuenta de los últimos 3 meses. Puede avanzar por partes: lo que llene se guarda. El enlace vence el ${fechaHora(expira)}.`;
  // wa.me necesita el numero con codigo de pais y sin signos.
  const digitos = String(telefono || '').replace(/\D/g, '');
  const numeroWa = digitos.length === 8 ? `502${digitos}` : digitos.length > 8 ? digitos : '';

  async function copiar() {
    await navigator.clipboard.writeText(url);
    setCopiado(true);
    setTimeout(() => setCopiado(false), 2500);
  }

  return (
    <div className="stack">
      <div className="campo">
        <span className="etiqueta">Enlace para el afianzado</span>
        <div className="row" style={{ flexWrap: 'nowrap' }}>
          <input className="control" readOnly value={url} onFocus={(e) => e.target.select()} aria-label="Enlace del portal" />
          <button className="btn btn-secundario" onClick={copiar}>
            <Copy size={16} aria-hidden="true" /> {copiado ? 'Copiado' : 'Copiar'}
          </button>
        </div>
        <span className="ayuda">Vence el {fechaHora(expira)}. Es personal y sirve para un solo envío.</span>
      </div>
      <div className="row">
        <a className="btn btn-secundario" href={`https://wa.me/${numeroWa}?text=${encodeURIComponent(mensaje)}`} target="_blank" rel="noreferrer">
          <MessageCircle size={16} aria-hidden="true" /> Enviar por WhatsApp
        </a>
        <a
          className="btn btn-secundario"
          href={`mailto:${encodeURIComponent(correo || '')}?subject=${encodeURIComponent('Fidelis: formulario para su fianza de consignación')}&body=${encodeURIComponent(mensaje)}`}
        >
          <Mail size={16} aria-hidden="true" /> Enviar por correo
        </a>
      </div>
    </div>
  );
}
