import { Auth } from '@supabase/auth-ui-react'
import { ThemeSupa } from '@supabase/auth-ui-shared'
import { supabase } from './lib/supabase'

export default function LoginPage() {
  return (
    <div
      style={{
        maxWidth: 420,
        margin: '80px auto',
        padding: '0 20px',
        color: '#d7e4ee',
      }}
    >
      <h1
        style={{
          textAlign: 'center',
          fontFamily: 'var(--font-title, Arial, sans-serif)',
          fontSize: '24px',
          letterSpacing: '1px',
          marginBottom: '24px',
        }}
      >
        LA GRAN IMPLOSIÓN
      </h1>
      <Auth
        supabaseClient={supabase}
        appearance={{ theme: ThemeSupa }}
        theme="dark"
        providers={[]}
        localization={{
          variables: {
            sign_in: {
              email_label: 'Correo',
              password_label: 'Contraseña',
              button_label: 'Entrar',
              email_input_placeholder: 'tu@email.com',
              password_input_placeholder: 'Tu contraseña',
            },
            sign_up: {
              email_label: 'Correo',
              password_label: 'Contraseña',
              button_label: 'Crear cuenta',
              email_input_placeholder: 'tu@email.com',
              password_input_placeholder: 'Elige una contraseña',
            },
          },
        }}
      />
    </div>
  )
}