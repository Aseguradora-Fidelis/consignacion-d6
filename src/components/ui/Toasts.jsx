import { createContext, useCallback, useContext, useMemo, useState } from 'react';
import { X } from 'lucide-react';
import { mensajeError } from '../../lib/errores';

const ToastContext = createContext(null);

export function ToastProvider({ children }) {
  const [toasts, setToasts] = useState([]);

  const quitar = useCallback((id) => setToasts((t) => t.filter((x) => x.id !== id)), []);

  const mostrar = useCallback((texto, tono = 'ok') => {
    const id = Math.random().toString(36).slice(2);
    setToasts((t) => [...t.slice(-3), { id, texto, tono }]);
    setTimeout(() => quitar(id), tono === 'critico' ? 9000 : 5000);
  }, [quitar]);

  const api = useMemo(() => ({
    ok: (texto) => mostrar(texto, 'ok'),
    error: (error) => mostrar(mensajeError(error), 'critico'),
  }), [mostrar]);

  return (
    <ToastContext.Provider value={api}>
      {children}
      <div className="toasts" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast ${t.tono}`} role={t.tono === 'critico' ? 'alert' : 'status'}>
            <span style={{ flex: 1 }}>{t.texto}</span>
            <button
              className="toast-cerrar"
              onClick={() => quitar(t.id)}
              aria-label="Cerrar aviso"
              style={{ display: 'inline-grid', placeItems: 'center', background: 'none', border: 0, color: 'inherit', cursor: 'pointer', padding: 0 }}
            >
              <X size={16} aria-hidden="true" />
            </button>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

// eslint-disable-next-line react-refresh/only-export-components
export function useToast() {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error('useToast debe usarse dentro de ToastProvider');
  return ctx;
}
