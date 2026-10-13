// Exportaciones a Excel. La libreria se carga solo cuando alguien descarga.
export async function descargarExcel(nombreArchivo, hoja, filas) {
  const XLSX = await import('xlsx');
  const libro = XLSX.utils.book_new();
  const datos = XLSX.utils.json_to_sheet(filas);
  const columnas = Object.keys(filas[0] || {});
  datos['!cols'] = columnas.map((c) => ({
    wch: Math.min(48, Math.max(c.length, ...filas.slice(0, 200).map((f) => String(f[c] ?? '').length)) + 2),
  }));
  XLSX.utils.book_append_sheet(libro, datos, hoja.slice(0, 31));
  XLSX.writeFile(libro, nombreArchivo);
}
