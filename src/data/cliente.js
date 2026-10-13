import { QueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: (intentos, error) => intentos < 2 && !/permiso|permission|JWT/i.test(error?.message || ''),
      refetchOnWindowFocus: true,
    },
  },
});

// Lanza el error de Supabase para que React Query lo maneje.
export async function dato(promesa) {
  const { data, error, count } = await promesa;
  if (error) throw error;
  return count === undefined || count === null ? data : { data, count };
}

export async function rpc(nombre, args) {
  const { data, error } = await supabase.rpc(nombre, args);
  if (error) throw error;
  return data;
}
