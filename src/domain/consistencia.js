// Consistencia cruzada del expediente (AGENTS.md, nivel 3): compara lo que escribio
// la marca al pedir el alta, lo que declaro el afianzado en el IVE y la resolucion.

const CONECTORES = new Set(['DE', 'DEL', 'LA', 'LOS', 'LAS', 'Y']);

export function normalizarTexto(valor) {
  return String(valor || '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toUpperCase()
    .replace(/[^A-Z0-9 ]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export function normalizarId(valor) {
  return String(valor || '').toUpperCase().replace(/[^0-9K]/g, '');
}

function palabras(valor) {
  return normalizarTexto(valor).split(' ').filter((p) => p.length > 1 && !CONECTORES.has(p));
}

// Coinciden si todas las palabras del nombre mas corto estan en el mas largo.
// "JUAN PEREZ" coincide con "JUAN CARLOS PEREZ LOPEZ" y no con "JUANA PEREZ".
export function nombresCoinciden(a, b) {
  const pa = palabras(a);
  const pb = palabras(b);
  if (!pa.length || !pb.length) return false;
  const [corto, largo] = pa.length <= pb.length ? [pa, pb] : [pb, pa];
  return corto.every((p) => largo.includes(p));
}

export function nombreDeclarado(ive = {}) {
  if (ive.razonSocial) return ive.razonSocial;
  return [ive.primerNombre, ive.segundoNombre, ive.primerApellido, ive.segundoApellido, ive.apellidoCasada]
    .filter(Boolean)
    .join(' ');
}

export function revisarConsistencia({ solicitud, ive }) {
  const d = ive || {};
  const hayIve = Boolean(ive);
  const filas = [];

  const declarado = nombreDeclarado(d);
  filas.push({
    dato: 'Nombre o razón social',
    marca: solicitud.cliente_nombre_tmp,
    ive: declarado,
    resultado: !hayIve ? 'sin_dato' : nombresCoinciden(solicitud.cliente_nombre_tmp, declarado) ? 'coincide' : 'difiere',
  });

  const nitIve = d.nitEntidad || d.nit;
  filas.push({
    dato: 'NIT',
    marca: solicitud.cliente_nit_tmp,
    ive: nitIve,
    resultado: !hayIve || !solicitud.cliente_nit_tmp || !nitIve
      ? 'sin_dato'
      : normalizarId(solicitud.cliente_nit_tmp) === normalizarId(nitIve) ? 'coincide' : 'difiere',
  });

  const correoIve = d.correoEmpresa || d.correo;
  filas.push({
    dato: 'Correo',
    marca: solicitud.cliente_email_tmp,
    ive: correoIve,
    resultado: !hayIve || !correoIve
      ? 'sin_dato'
      : String(solicitud.cliente_email_tmp || '').toLowerCase().trim() === String(correoIve).toLowerCase().trim()
        ? 'coincide' : 'difiere',
  });

  const limite = Number(solicitud.resolucion_marca_monto || 0);
  const monto = Number(solicitud.monto_solicitado || 0);
  filas.push({
    dato: 'Monto solicitado frente al límite de la marca',
    marca: limite || null,
    ive: monto,
    moneda: true,
    resultado: !limite ? 'sin_dato' : monto <= limite ? 'coincide' : 'difiere',
  });

  return filas;
}

// Lo que declaro el distribuidor y conviene tener a la vista al consultar el expediente.
export function alertasExpediente({ solicitud, ive, hoy = new Date() }) {
  const alertas = [];
  const d = ive || {};
  if (d.esPEP === 'SI' || d.repEsPEP === 'SI') {
    alertas.push({ tono: 'critico', texto: 'Se declara persona expuesta políticamente (PEP).' });
  }
  if (d.parientePEP === 'SI' || d.asociadoPEP === 'SI') {
    alertas.push({ tono: 'atencion', texto: 'Declara parentesco o asociación con una persona expuesta políticamente.' });
  }
  if (d.contratistaEstado === 'SI') {
    alertas.push({ tono: 'atencion', texto: 'Declara ser contratista o proveedor del Estado.' });
  }
  if (solicitud.resolucion_marca_fecha) {
    const vence = new Date(`${solicitud.resolucion_marca_fecha}T00:00:00`);
    vence.setDate(vence.getDate() + 30);
    const dias = Math.round((vence - hoy) / 86_400_000);
    if (dias < 0) alertas.push({ tono: 'critico', texto: 'La resolución de la marca venció: pasaron más de 30 días sin contrato firmado.' });
    else if (dias <= 7) alertas.push({ tono: 'atencion', texto: `La resolución de la marca vence en ${dias} días.` });
  } else {
    alertas.push({ tono: 'atencion', texto: 'La marca no registró los datos de su resolución de crédito.' });
  }
  return alertas;
}
