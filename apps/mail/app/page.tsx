import HomeContent from '@/components/home/HomeContent';
import { LoginClient } from '@/app/(auth)/login/login-client';
import { authProxy } from '@/lib/auth-proxy';
import type { Route } from './+types/page';
import { redirect, useLoaderData } from 'react-router';

const BILLING_DISABLED = import.meta.env.VITE_PUBLIC_BILLING_DISABLED === 'true';

export async function clientLoader({ request }: Route.ClientLoaderArgs) {
  const session = await authProxy.api.getSession({ headers: request.headers });
  if (session?.user.id) throw redirect('/mail/inbox');

  if (BILLING_DISABLED) {
    const response = await fetch(import.meta.env.VITE_PUBLIC_BACKEND_URL + '/api/public/providers');
    const data = (await response.json()) as { allProviders: any[] };
    return { allProviders: data.allProviders, isProd: !import.meta.env.DEV };
  }

  return null;
}

export default function Home() {
  const data = useLoaderData<typeof clientLoader>();

  if (BILLING_DISABLED && data) {
    return (
      <div className="flex min-h-screen w-full flex-col bg-white dark:bg-black">
        <LoginClient providers={data.allProviders} isProd={data.isProd} />
      </div>
    );
  }

  return <HomeContent />;
}
