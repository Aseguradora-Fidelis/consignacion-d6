import { useEffect } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { dato } from './cliente';

// Una sola suscripcion en vivo por sesion (la abre AppShell). Si dos componentes
// abren el mismo canal, Supabase rechaza el segundo y la pagina se cae.
export function useNotificacionesEnVivo(userId) {
  const qc = useQueryClient();
  useEffect(() => {
    if (!userId) return undefined;
    const canal = supabase
      .channel(`notificaciones:${userId}:${Math.random().toString(36).slice(2)}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'notificaciones', filter: `user_id=eq.${userId}` },
        () => qc.invalidateQueries({ queryKey: ['notificaciones', userId] }))
      .subscribe();
    return () => {
      supabase.removeChannel(canal);
    };
  }, [userId, qc]);
}

export function useNotificaciones(userId) {
  return useQuery({
    queryKey: ['notificaciones', userId],
    enabled: Boolean(userId),
    refetchInterval: 120_000,
    queryFn: () => dato(
      supabase.from('notificaciones').select('*').eq('user_id', userId).order('created_at', { ascending: false }).limit(30),
    ),
  });
}

export function useMarcarLeidas(userId) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (ids) => dato(supabase.from('notificaciones').update({ leido: true }).in('id', ids).select('id')),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['notificaciones', userId] }),
  });
}
