// Formulario IVE del portal del afianzado.
// Persona individual: ASR-32 de Fidelis y su cuestionario. Persona juridica: campos del IVE-IR-02.
// Los campos obligatorios coinciden con validar_datos_ive_d6 (migracion 036). Si cambia uno,
// hay que cambiar el otro: la prueba test/formularioIve.test.js lo verifica.
import { validateDPI, validateEmail, validateNIT, validatePhone } from './validators.js';

export const VERSION_FORMULARIO = 'FIDELIS-D6-2026.4';
// Version del texto de la declaracion de veracidad. El servidor la guarda con la huella del envio.
export const VERSION_DECLARACION = 'D6-DECLARACION-2026.1';
export const TIPO_IVE = { INDIVIDUAL: 'IVE-ASS-01', JURIDICA: 'IVE-ASS-02' };

const SI_NO = [{ valor: 'NO', texto: 'No' }, { valor: 'SI', texto: 'Sí' }];
const ESTADO_CIVIL = ['Soltero(a)', 'Casado(a)', 'Unido(a)', 'Divorciado(a)', 'Viudo(a)'].map((v) => ({ valor: v, texto: v }));
const DEPARTAMENTOS = [
  'Alta Verapaz', 'Baja Verapaz', 'Chimaltenango', 'Chiquimula', 'El Progreso', 'Escuintla', 'Guatemala',
  'Huehuetenango', 'Izabal', 'Jalapa', 'Jutiapa', 'Petén', 'Quetzaltenango', 'Quiché', 'Retalhuleu',
  'Sacatepéquez', 'San Marcos', 'Santa Rosa', 'Sololá', 'Suchitepéquez', 'Totonicapán', 'Zacapa',
].map((v) => ({ valor: v, texto: v }));

const f = (id, label, tipo = 'text', extra = {}) => ({ id, label, tipo, ...extra });

// Persona individual: los datos del ASR-32 de Fidelis y de su cuestionario, en 5 partes y sin
// preguntar dos veces lo mismo. Lo que la marca ya escribio llega precargado para confirmar.
// Algunos datos que pide el formato se deducen de otros (ver derivar): el puesto de quien tiene
// negocio propio, los rangos IVE de ingresos y egresos, el lugar y el tipo de gestion.
const RANGOS_INGRESO = [
  ['0.00 a 3,000.00', 3000], ['3,000.01 a 10,000.00', 10000], ['10,000.01 a 50,000.00', 50000],
  ['50,000.01 a 100,000.00', 100000], ['100,000.01 a 200,000.00', 200000], ['Más de 200,000.00', Infinity],
];
const NIVEL_EDUCATIVO = ['Primaria', 'Básico', 'Diversificado', 'Universitario', 'Postgrado'].map((v) => ({ valor: v, texto: v }));
const AYUDA_PEP = 'Persona Expuesta Políticamente: quien desempeña o ha desempeñado un cargo público relevante en Guatemala '
  + 'u otro país, un cargo prominente en un organismo internacional, o es dirigente de un partido político.';
const empleado = (d) => d.fuenteIngresos === 'RELACION_DEPENDENCIA' || d.fuenteIngresos === 'AMBOS';

export function rangoIve(monto) {
  const n = Number(monto);
  if (!Number.isFinite(n) || String(monto).trim() === '') return '';
  return RANGOS_INGRESO.find(([, tope]) => n <= tope)[0];
}

export const SECCIONES_INDIVIDUAL = [
  {
    titulo: 'Sus datos',
    descripcion: 'Si su marca ya llenó algo, solo revíselo.',
    campos: [
      f('primerNombre', 'Primer nombre', 'text', { requerido: true }),
      f('segundoNombre', 'Segundo nombre'),
      f('primerApellido', 'Primer apellido', 'text', { requerido: true }),
      f('segundoApellido', 'Segundo apellido'),
      f('apellidoCasada', 'Apellido de casada', 'text', { cuando: (d) => d.genero === 'F' && d.estadoCivil === 'Casado(a)' }),
      f('dpi', 'DPI (CUI)', 'text', { requerido: true, ayuda: '13 dígitos, sin espacios.', inputMode: 'numeric', formato: 'dpi' }),
      f('nit', 'NIT', 'text', { requerido: true, formato: 'nit' }),
      f('telefono', 'Celular', 'tel', { requerido: true, formato: 'telefono' }),
      f('correo', 'Correo electrónico', 'email', { requerido: true, formato: 'correo' }),
      f('fechaNacimiento', 'Fecha de nacimiento', 'date', { requerido: true }),
      f('genero', 'Género', 'select', { requerido: true, opciones: [{ valor: 'M', texto: 'Masculino' }, { valor: 'F', texto: 'Femenino' }] }),
      f('estadoCivil', 'Estado civil', 'select', { requerido: true, opciones: ESTADO_CIVIL }),
      f('nacionalidad', 'Nacionalidad', 'text', { requerido: true, inicial: 'Guatemalteca' }),
      f('profesion', 'Profesión u oficio', 'text', { requerido: true, inicial: 'Comerciante' }),
      f('nivelEducativo', 'Nivel educativo', 'select', { opciones: NIVEL_EDUCATIVO }),
      f('lugarNacimiento', 'Lugar de nacimiento'),
      f('lugarEmisionDpi', 'Lugar de emisión del DPI'),
      f('celular', 'Teléfono fijo', 'tel'),
    ],
  },
  {
    titulo: 'Dónde vive',
    campos: [
      f('direccion', 'Dirección de su casa', 'text', { requerido: true, ancho: 'completo', ayuda: 'Calle o avenida, número, colonia y zona.' }),
      f('municipio', 'Municipio', 'text', { requerido: true }),
      f('departamento', 'Departamento', 'select', { requerido: true, opciones: DEPARTAMENTOS }),
      f('tipoVivienda', 'La casa es', 'select', { opciones: [{ valor: 'PROPIA', texto: 'Propia' }, { valor: 'ALQUILADA', texto: 'Alquilada' }] }),
      f('tiempoResidir', 'Tiempo de vivir ahí', 'text', { ayuda: 'Por ejemplo: 2 años.' }),
      f('pagoVivienda', 'Pago mensual de la casa (Q)', 'number', { ayuda: 'Alquiler o cuota, si paga.' }),
      f('otraDireccionCobros', '¿Los cobros se le hacen en otra dirección?', 'sino', { opciones: SI_NO }),
      f('direccionCobros', 'Dirección para cobros', 'text', { ancho: 'completo', requerido: true, cuando: (d) => d.otraDireccionCobros === 'SI' }),
      f('poseeVehiculo', '¿Tiene vehículo?', 'sino', { opciones: SI_NO }),
      f('vehiculoMarca', 'Marca', 'text', { cuando: (d) => d.poseeVehiculo === 'SI' }),
      f('vehiculoModelo', 'Modelo (año)', 'text', { cuando: (d) => d.poseeVehiculo === 'SI', inputMode: 'numeric' }),
      f('vehiculoColor', 'Color', 'text', { cuando: (d) => d.poseeVehiculo === 'SI' }),
      f('vehiculoPlaca', 'Placa', 'text', { cuando: (d) => d.poseeVehiculo === 'SI' }),
    ],
  },
  {
    titulo: 'Su negocio e ingresos',
    campos: [
      f('fuenteIngresos', 'Sus ingresos vienen de', 'select', {
        requerido: true,
        inicial: 'NEGOCIO_PROPIO',
        opciones: [
          { valor: 'NEGOCIO_PROPIO', texto: 'Mi negocio' },
          { valor: 'RELACION_DEPENDENCIA', texto: 'Un empleo' },
          { valor: 'AMBOS', texto: 'Los dos' },
        ],
      }),
      f('lugarTrabajo', 'Nombre de su negocio', 'text', { requerido: true, ayuda: 'Si trabaja para alguien, el nombre de la empresa.' }),
      f('negocioEnCasa', '¿El negocio está en la misma dirección de su casa?', 'sino', { opciones: SI_NO }),
      f('direccionTrabajo', 'Dirección del negocio', 'text', { ancho: 'completo', cuando: (d) => d.negocioEnCasa !== 'SI' }),
      f('telefonoTrabajo', 'Teléfono del negocio', 'tel'),
      f('antiguedad', 'Tiempo con el negocio o empleo', 'text', { ayuda: 'Por ejemplo: 4 años.' }),
      f('cargoTrabajo', 'Puesto', 'text', { requerido: true, cuando: empleado }),
      f('jefeInmediato', 'Jefe inmediato', 'text', { cuando: empleado }),
      f('salarioActual', 'Ingreso mensual aproximado (Q)', 'number', { requerido: true }),
      f('otrosIngresos', 'Otros ingresos al mes (Q)', 'number'),
      f('fuenteOtrosIngresos', 'De dónde vienen esos otros ingresos', 'text', { cuando: (d) => Number(d.otrosIngresos) > 0 }),
      f('gastosMensuales', 'Gastos mensuales aproximados (Q)', 'number', { requerido: true }),
      f('prestamos', '¿Tiene préstamos?', 'sino', { opciones: SI_NO }),
      f('prestamoValor', 'Saldo del préstamo (Q)', 'number', { cuando: (d) => d.prestamos === 'SI' }),
      f('prestamoCuota', 'Cuota mensual (Q)', 'number', { cuando: (d) => d.prestamos === 'SI' }),
      f('tieneOtrasEmpresas', '¿Tiene otras empresas?', 'sino', { opciones: SI_NO }),
      f('empresa1', 'Empresa', 'text', { cuando: (d) => d.tieneOtrasEmpresas === 'SI' }),
      f('empresa2', 'Otra empresa', 'text', { cuando: (d) => d.tieneOtrasEmpresas === 'SI' }),
      f('tieneTiendas', '¿Tiene más puntos de venta?', 'sino', { opciones: SI_NO }),
      f('tiendas', 'Puntos de venta', 'filas', {
        ancho: 'completo',
        cuando: (d) => d.tieneTiendas === 'SI',
        columnas: [
          f('departamento', 'Departamento', 'select', { opciones: DEPARTAMENTOS }),
          f('municipio', 'Municipio'),
          f('direccion', 'Dirección'),
          f('telefono', 'Teléfono', 'tel'),
          f('jefe', 'Encargado'),
        ],
      }),
    ],
  },
  {
    titulo: 'Referencias',
    descripcion: 'Una persona de su familia y, si quiere, un proveedor. Fidelis puede llamarles.',
    campos: [
      f('refNombre1', 'Nombre de un familiar', 'text', { requerido: true }),
      f('refTelefono1', 'Teléfono', 'tel', { requerido: true, formato: 'telefono' }),
      f('refRelacion1', 'Parentesco', 'text', { ayuda: 'Por ejemplo: esposa, hermano.' }),
      f('refNombre2', 'Otro familiar', 'text'),
      f('refTelefono2', 'Teléfono', 'tel', { cuando: (d) => Boolean(d.refNombre2) }),
      f('refRelacion2', 'Parentesco', 'text', { cuando: (d) => Boolean(d.refNombre2) }),
      f('refComercial1', 'Un proveedor suyo'),
      f('refComercialTel1', 'Teléfono del proveedor', 'tel', { cuando: (d) => Boolean(d.refComercial1) }),
    ],
  },
  {
    titulo: 'Preguntas de ley',
    descripcion: 'La Ley Contra el Lavado de Dinero u Otros Activos obliga a hacer estas preguntas a todos los clientes.',
    campos: [
      f('esPEP', '¿Es usted una Persona Expuesta Políticamente (PEP)?', 'sino', { opciones: SI_NO, requerido: true, ayuda: AYUDA_PEP }),
      f('pepDetalle', 'Cargo, institución, país y periodo', 'textarea', { cuando: (d) => d.esPEP === 'SI', requerido: true, ancho: 'completo' }),
      f('parientePEP', '¿Tiene parentesco con una Persona Expuesta Políticamente (PEP)?', 'sino', { opciones: SI_NO, requerido: true }),
      f('parientePepDetalle', 'Nombre de la PEP, parentesco y cargo', 'textarea', { cuando: (d) => d.parientePEP === 'SI', requerido: true, ancho: 'completo' }),
      f('asociadoPEP', '¿Es asociado cercano de una Persona Expuesta Políticamente (PEP)?', 'sino', { opciones: SI_NO, requerido: true }),
      f('asociadoPepDetalle', 'Nombre de la PEP, cargo y motivo de la relación', 'textarea', { cuando: (d) => d.asociadoPEP === 'SI', requerido: true, ancho: 'completo' }),
      f('contratistaEstado', '¿Es Contratista o Proveedor del Estado (CPE)?', 'sino', { opciones: SI_NO, requerido: true }),
      f('actuaTercero', '¿Hace este trámite a través de un mandatario?', 'sino', { opciones: SI_NO, requerido: true }),
      f('mandatarioNombre', 'Nombre completo del mandatario', 'text', { cuando: (d) => d.actuaTercero === 'SI', requerido: true }),
      f('mandatarioDpi', 'DPI o pasaporte del mandatario', 'text', { cuando: (d) => d.actuaTercero === 'SI', requerido: true, inputMode: 'numeric' }),
    ],
  },
];

// Datos del formato que salen de otros ya respondidos. Se calculan al guardar y al enviar.
export function derivar(tipoPersona, d) {
  if (tipoPersona === 'JURIDICA') return d;
  const r = { ...d };
  if (!empleado(r)) r.cargoTrabajo = r.cargoTrabajo || 'Propietario';
  if (r.salarioActual !== undefined && r.salarioActual !== '') {
    r.ingresosMensuales = rangoIve(Number(r.salarioActual || 0) + Number(r.otrosIngresos || 0));
  }
  if (r.gastosMensuales !== undefined && r.gastosMensuales !== '') r.egresosMensuales = rangoIve(r.gastosMensuales);
  if (r.negocioEnCasa === 'SI') r.direccionTrabajo = [r.direccion, r.municipio, r.departamento].filter(Boolean).join(', ');
  if (r.fuenteIngresos === 'NEGOCIO_PROPIO' || r.fuenteIngresos === 'AMBOS') {
    r.empresaNombre = r.lugarTrabajo;
    r.empresaDireccion = r.direccionTrabajo;
  }
  r.lugarFirma = [r.municipio, r.departamento].filter(Boolean).join(', ');
  r.tipoGestion = r.tipoGestion || 'INICIO';
  return r;
}

// Campos del servidor que el portal no pregunta porque los deduce.
export const DERIVADOS = ['cargoTrabajo', 'ingresosMensuales', 'egresosMensuales'];

// Lo que la marca escribio al pedir el alta, llevado a los campos del formulario.
export function prellenadoDesdeMarca({ tipoPersona, nombres, apellidos, razonSocial, dpi, nit, telefono, correo }) {
  const partir = (t) => {
    const p = String(t || '').trim().split(/\s+/).filter(Boolean);
    return [p[0] || '', p.slice(1).join(' ')];
  };
  const limpio = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && String(v).trim() !== ''));
  if (tipoPersona === 'JURIDICA') {
    return limpio({ razonSocial, nitEntidad: nit, telefonoEmpresa: telefono, correoEmpresa: correo });
  }
  const [primerNombre, segundoNombre] = partir(nombres);
  const [primerApellido, segundoApellido] = partir(apellidos);
  return limpio({ primerNombre, segundoNombre, primerApellido, segundoApellido, dpi, nit, telefono, correo });
}

export const SECCIONES_JURIDICA = [
  {
    titulo: 'Datos de la entidad',
    campos: [
      f('razonSocial', 'Razón social completa', 'text', { requerido: true, ancho: 'completo' }),
      f('nombreComercial', 'Nombre comercial'),
      f('tipoEntidad', 'Tipo de entidad', 'select', {
        opciones: ['Sociedad anónima', 'Sociedad de responsabilidad limitada', 'Copropiedad', 'Otra'].map((v) => ({ valor: v, texto: v })),
      }),
      f('nitEntidad', 'NIT de la entidad', 'text', { requerido: true, formato: 'nit' }),
      f('actividadEconomica', 'Actividad económica principal', 'text', { requerido: true }),
      f('paisConstitucion', 'País de constitución', 'text', { requerido: true, inicial: 'Guatemala' }),
    ],
  },
  {
    titulo: 'Constitución y registro',
    campos: [
      f('escrituraNumero', 'Número de escritura de constitución', 'text', { requerido: true }),
      f('escrituraFecha', 'Fecha de la escritura', 'date', { requerido: true }),
      f('notarioConstitucion', 'Notario autorizante', 'text', { requerido: true }),
      f('modificaciones', 'Modificaciones a la escritura (número y fecha)', 'textarea', { ancho: 'completo' }),
      f('registroMercantil', 'Inscripción en el Registro Mercantil (registro, folio, libro)', 'text', { requerido: true }),
      f('patenteSociedad', 'Patente de sociedad (registro, folio, libro)', 'text', { requerido: true }),
      f('patenteEmpresa', 'Patente de empresa (registro, folio, libro)', 'text', { requerido: true }),
    ],
  },
  {
    titulo: 'Sede y contacto',
    campos: [
      f('direccionSede', 'Dirección de la sede (calle, número, zona)', 'text', { requerido: true, ancho: 'completo' }),
      f('municipioSede', 'Municipio'),
      f('departamentoSede', 'Departamento', 'select', { opciones: DEPARTAMENTOS }),
      f('telefonoEmpresa', 'Teléfono', 'tel', { requerido: true, formato: 'telefono' }),
      f('correoEmpresa', 'Correo electrónico', 'email', { requerido: true, formato: 'correo' }),
      f('sitioWeb', 'Sitio web'),
    ],
  },
  {
    titulo: 'Información económica',
    campos: [
      f('numeroEmpleados', 'Número de empleados', 'number'),
      f('ingresosMensuales', 'Ingresos mensuales aproximados (Q)', 'number'),
      f('egresosMensuales', 'Egresos mensuales aproximados (Q)', 'number'),
      f('principalesProveedores', 'Principales proveedores y clientes', 'textarea', { ancho: 'completo' }),
      f('contratistaEstado', '¿La entidad es Contratista o Proveedora del Estado (CPE)?', 'sino', { opciones: SI_NO, requerido: true }),
    ],
  },
  {
    titulo: 'Representante legal',
    campos: [
      f('repNombreCompleto', 'Nombre completo', 'text', { requerido: true, ancho: 'completo' }),
      f('repCargo', 'Cargo', 'text', { requerido: true }),
      f('repDpi', 'DPI (CUI)', 'text', { requerido: true, inputMode: 'numeric', formato: 'dpi' }),
      f('repNit', 'NIT', 'text', { requerido: true, formato: 'nit' }),
      f('repNacionalidad', 'Nacionalidad', 'text', { inicial: 'Guatemalteca' }),
      f('repTelefono', 'Teléfono', 'tel'),
      f('repCorreo', 'Correo electrónico', 'email'),
      f('repNombramientoNotario', 'Notario del acta de nombramiento', 'text', { requerido: true }),
      f('repNombramientoFecha', 'Fecha del nombramiento', 'date', { requerido: true }),
      f('repNombramientoRegistro', 'Inscripción del nombramiento (registro, folio, libro)'),
      f('repEsPEP', '¿El representante legal es una Persona Expuesta Políticamente (PEP)?', 'sino', { opciones: SI_NO, requerido: true }),
      f('repPepDetalle', 'Cargo, institución y periodo', 'textarea', { cuando: (d) => d.repEsPEP === 'SI', requerido: true, ancho: 'completo' }),
    ],
  },
  {
    titulo: 'Referencias',
    campos: [
      f('refComercial1', 'Referencia comercial: empresa'),
      f('refComercialTel1', 'Teléfono de la referencia comercial', 'tel'),
      f('refBancaria', 'Referencia bancaria: banco'),
      f('refBancariaTel', 'Teléfono del banco', 'tel'),
    ],
  },
];

export function seccionesPara(tipoPersona) {
  return tipoPersona === 'JURIDICA' ? SECCIONES_JURIDICA : SECCIONES_INDIVIDUAL;
}

export function datosIniciales(tipoPersona, previos = {}) {
  const datos = { tipoIve: TIPO_IVE[tipoPersona] || TIPO_IVE.INDIVIDUAL, versionFormulario: VERSION_FORMULARIO };
  for (const s of seccionesPara(tipoPersona)) {
    for (const c of s.campos) {
      datos[c.id] = c.inicial ?? (c.tipo === 'filas' ? [] : '');
    }
  }
  return { ...datos, ...previos, tipoIve: TIPO_IVE[tipoPersona] || TIPO_IVE.INDIVIDUAL, versionFormulario: VERSION_FORMULARIO };
}

const FORMATOS = {
  dpi: validateDPI,
  nit: validateNIT,
  correo: validateEmail,
  telefono: validatePhone,
};

export function camposVisibles(seccion, datos) {
  return seccion.campos.filter((c) => !c.cuando || c.cuando(datos));
}

export function validarFormulario(tipoPersona, datosCrudos) {
  const datos = derivar(tipoPersona, datosCrudos);
  const errores = {};
  for (const seccion of seccionesPara(tipoPersona)) {
    for (const campo of camposVisibles(seccion, datos)) {
      const valor = datos[campo.id];
      const vacio = valor === undefined || valor === null || String(valor).trim() === '';
      if (campo.requerido && vacio) {
        errores[campo.id] = campo.tipo === 'sino' ? 'Elija una opción.' : 'Este dato es obligatorio.';
        continue;
      }
      if (!vacio && campo.formato) {
        const error = FORMATOS[campo.formato](valor);
        if (error) errores[campo.id] = error;
      }
      if (!vacio && campo.tipo === 'number' && (Number.isNaN(Number(valor)) || Number(valor) < 0)) {
        errores[campo.id] = 'Ingrese un número válido.';
      }
    }
  }
  if (!datos.declaracionVeracidad) errores.declaracionVeracidad = 'Debe aceptar la declaración para enviar.';
  return errores;
}

// Campos que exige el servidor. Se usa en pruebas para que el formulario no quede corto.
export const REQUERIDOS_SERVIDOR = {
  INDIVIDUAL: ['primerNombre', 'primerApellido', 'dpi', 'nit', 'telefono', 'correo', 'fechaNacimiento', 'direccion', 'municipio', 'departamento', 'nacionalidad', 'profesion', 'lugarTrabajo', 'cargoTrabajo', 'fuenteIngresos', 'ingresosMensuales', 'egresosMensuales', 'estadoCivil', 'esPEP', 'parientePEP', 'asociadoPEP', 'refNombre1', 'refTelefono1'],
  JURIDICA: ['razonSocial', 'nitEntidad', 'actividadEconomica', 'paisConstitucion', 'escrituraNumero', 'escrituraFecha', 'notarioConstitucion', 'patenteSociedad', 'patenteEmpresa', 'registroMercantil', 'direccionSede', 'telefonoEmpresa', 'correoEmpresa', 'repNombreCompleto', 'repDpi', 'repNit', 'repCargo', 'repNombramientoNotario', 'repNombramientoFecha', 'repEsPEP'],
};

export function seccionDeCampo(tipoPersona, id) {
  return seccionesPara(tipoPersona).findIndex((s) => s.campos.some((c) => c.id === id));
}

// Lo que falta en cada parte, para mostrar el avance y la lista final. No cuenta la declaracion.
export function pendientesPorSeccion(tipoPersona, datosCrudos) {
  const errores = validarFormulario(tipoPersona, { ...datosCrudos, declaracionVeracidad: true });
  return seccionesPara(tipoPersona).map((s, indice) => {
    const faltan = s.campos.filter((c) => errores[c.id]).map((c) => ({ id: c.id, label: c.label, error: errores[c.id] }));
    const llenos = s.campos.filter((c) => {
      const v = datosCrudos?.[c.id];
      return Array.isArray(v) ? v.length > 0 : v !== undefined && v !== null && String(v).trim() !== '';
    }).length;
    return { indice, titulo: s.titulo, faltan, llenos };
  });
}

// Datos que se calculan al guardar y no tienen pregunta propia.
const ETIQUETAS_CALCULADAS = {
  empresaNombre: 'Empresa (formato IVE)',
  empresaDireccion: 'Dirección de la empresa (formato IVE)',
  lugarFirma: 'Lugar de firma',
  tipoGestion: 'Tipo de gestión',
  tipoIve: 'Formato IVE',
  versionFormulario: 'Versión del formulario',
};

export function definicionCampo(id) {
  for (const s of [...SECCIONES_INDIVIDUAL, ...SECCIONES_JURIDICA]) {
    const c = s.campos.find((x) => x.id === id);
    if (c) return c;
  }
  return null;
}

export function etiquetaCampo(id) {
  return definicionCampo(id)?.label || ETIQUETAS_CALCULADAS[id] || id;
}

export function textoValor(campo, valor) {
  if (valor === undefined || valor === null || valor === '') return '';
  if (campo.tipo === 'filas') {
    if (!Array.isArray(valor) || !valor.length) return '';
    return valor.map((fila) => campo.columnas.map((c) => fila[c.id]).filter(Boolean).join(' · ')).join('. ');
  }
  if (campo.opciones) return campo.opciones.find((o) => o.valor === valor)?.texto || valor;
  if (campo.tipo === 'date' && /^\d{4}-\d{2}-\d{2}$/.test(valor)) return valor.split('-').reverse().join('/');
  return String(valor);
}
