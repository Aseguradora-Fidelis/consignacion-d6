// Traduce errores de Supabase a mensajes que una persona puede accionar.
// Solo los RAISE EXCEPTION de nuestras RPC (codigo P0001) y los mensajes que lanza la propia app
// se muestran tal cual: ya vienen redactados para el usuario. El resto nunca muestra el texto
// tecnico de Postgres o del navegador, solo un mensaje generico con el codigo para soporte.
export const MENSAJE_GENERICO = 'No se pudo completar. Intente de nuevo o llame a Fidelis al 2285 7000.';

export function mensajeError(error) {
  if (!error) return MENSAJE_GENERICO;
  if (typeof error === 'string') return error;
  const texto = error.message || error.error_description || '';
  const codigo = String(error.code || '');

  if (/Invalid login credentials/i.test(texto)) return 'El correo o la contraseña no coinciden.';
  if (/Email not confirmed/i.test(texto)) return 'Confirme su correo antes de ingresar.';
  if (/Failed to fetch|NetworkError|network/i.test(texto)) return 'No hay conexión con el servidor. Revise su internet e intente de nuevo.';
  if (/JWT expired|invalid JWT/i.test(texto)) return 'Su sesión venció. Ingrese de nuevo.';
  if (codigo === 'over_request_rate_limit' || /rate limit|too many requests/i.test(texto)) {
    return 'Demasiados intentos seguidos. Espere un minuto e intente de nuevo.';
  }
  if (codigo === '42501' || /row-level security|permission denied/i.test(texto)) return 'No tiene permiso para esta acción.';
  if (codigo === '23505' || /duplicate key/i.test(texto)) return 'Ese registro ya existe.';
  if (/payload too large|exceeded the maximum allowed size/i.test(texto)) return 'El archivo supera el tamaño permitido (15 MB).';
  if (/mime type .* is not supported/i.test(texto)) return 'Solo se aceptan archivos PDF, PNG o JPG.';
  if (codigo === 'P0001' && texto) return texto;
  // Mensajes que lanza la app con new Error('...'). Un TypeError u otro error del navegador no entra.
  if (!codigo && error.name === 'Error' && texto) return texto;
  const referencia = codigo || (error.name && error.name !== 'Error' ? error.name : '');
  return referencia ? `${MENSAJE_GENERICO} (${referencia})` : MENSAJE_GENERICO;
}
