import { Component } from 'react';

// Si una pantalla falla, se muestra un aviso con salida en lugar de una pagina en blanco.
export default class ErrorAplicacion extends Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error) {
    return { error };
  }

  componentDidCatch(error, info) {
    console.error('Error de pantalla', error, info?.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="vacio" role="alert" style={{ margin: '2rem auto', maxWidth: 560 }}>
        <h3>Esta pantalla tuvo un problema</h3>
        <p>Sus datos no se perdieron. Vuelva a cargar la página. Si se repite, avise a Fidelis.</p>
        <div className="row" style={{ justifyContent: 'center', marginTop: '1rem' }}>
          <button className="btn btn-primario" onClick={() => window.location.reload()}>Volver a cargar</button>
          <a className="btn btn-secundario" href="/">Ir al inicio</a>
        </div>
      </div>
    );
  }
}
