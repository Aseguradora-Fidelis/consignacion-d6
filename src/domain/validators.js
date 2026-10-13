/**
 * Form Validation Helpers for NIT, Email, DPI/CUI, Amounts, Names, Phones
 */

export function validateEmail(email) {
  if (!email || !String(email).trim()) return 'El correo electrónico es requerido.';
  const regex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!regex.test(String(email).trim())) return 'Ingrese un correo electrónico válido (ejemplo@dominio.com).';
  return null;
}

export function validateNIT(nit) {
  if (!nit || !String(nit).trim()) return 'El NIT es requerido.';
  const clean = String(nit).replace(/[^0-9kK]/g, '');
  if (clean.length < 5 || clean.length > 12) return 'El NIT debe tener entre 5 y 12 caracteres (ej: 1234567-8).';
  return null;
}

export function validateDPI(dpi) {
  if (!dpi || !String(dpi).trim()) return 'El DPI/CUI es requerido.';
  const clean = String(dpi).replace(/\D/g, '');
  if (clean.length !== 13) return 'El DPI/CUI debe ser un número de exactamente 13 dígitos.';
  return null;
}

export function validateAmount(amount) {
  if (amount === undefined || amount === null || amount === '') return 'El monto es requerido.';
  const num = Number(String(amount).replace(/,/g, ''));
  if (isNaN(num) || num <= 0) return 'Ingrese un monto numérico mayor a 0.';
  return null;
}

export function validateName(name, fieldName = 'El nombre') {
  if (!name || !String(name).trim()) return `${fieldName} es requerido.`;
  const trimmed = String(name).trim();
  if (trimmed.length < 3) return `${fieldName} debe tener al menos 3 caracteres.`;
  // Text only check (letters, accents, spaces, dots, hyphens)
  const regex = /^[a-zA-ZáéíóúÁÉÍÓÚñÑ\s\.\,\'-]+$/;
  if (!regex.test(trimmed)) return `${fieldName} solo debe contener letras (no se permiten números ni símbolos numéricos).`;
  return null;
}

export function validatePhone(phone) {
  if (!phone || !String(phone).trim()) return 'El teléfono de contacto es requerido.';
  const clean = String(phone).replace(/\D/g, '');
  if (clean.length < 8 || clean.length > 15) return 'El número de teléfono debe tener entre 8 y 15 dígitos numéricos.';
  return null;
}

export function validateNumericOnly(val, fieldName = 'Este campo', expectedLength = null) {
  if (val === undefined || val === null || String(val).trim() === '') return `${fieldName} es requerido.`;
  const clean = String(val).replace(/\D/g, '');
  if (clean.length === 0) return `${fieldName} solo admite valores numéricos.`;
  if (expectedLength && clean.length !== expectedLength) return `${fieldName} debe tener exactamente ${expectedLength} dígitos numéricos.`;
  return null;
}

export function validateRequired(value, fieldName = 'Este campo') {
  if (value === undefined || value === null || String(value).trim() === '') {
    return `${fieldName} es requerido.`;
  }
  return null;
}

export function validateFianzaForm(formData) {
  const errors = {};

  const nameErr = validateName(formData.nombreCliente, 'El nombre del cliente');
  if (nameErr) errors.nombreCliente = nameErr;

  const benefErr = validateRequired(formData.nombreBeneficiario, 'El beneficiario');
  if (benefErr) errors.nombreBeneficiario = benefErr;

  const amountErr = validateAmount(formData.montoAfianzado);
  if (amountErr) errors.montoAfianzado = amountErr;

  if (formData.nitCliente) {
    const nitErr = validateNIT(formData.nitCliente);
    if (nitErr) errors.nitCliente = nitErr;
  }

  if (formData.dpiCliente) {
    const dpiErr = validateDPI(formData.dpiCliente);
    if (dpiErr) errors.dpiCliente = dpiErr;
  }

  if (formData.correoCliente) {
    const emailErr = validateEmail(formData.correoCliente);
    if (emailErr) errors.correoCliente = emailErr;
  }

  if (formData.telefonoCliente) {
    const phoneErr = validatePhone(formData.telefonoCliente);
    if (phoneErr) errors.telefonoCliente = phoneErr;
  }

  const contraterr = validateRequired(formData.contratoNumero, 'El número de contrato o escritura');
  if (contraterr) errors.contratoNumero = contraterr;

  return {
    isValid: Object.keys(errors).length === 0,
    errors,
  };
}
