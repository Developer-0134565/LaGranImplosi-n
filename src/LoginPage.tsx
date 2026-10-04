import { Auth } from '@supabase/auth-ui-react'
import { ThemeSupa } from '@supabase/auth-ui-shared'
import { supabase } from './lib/supabase'
import { useI18n } from './i18n/I18nContext'
import type { Lang } from './lib/i18n'

import type { I18nVariables } from '@supabase/auth-ui-shared'

/**
 * `Auth` de @supabase/auth-ui-react NO trae i18n: no acepta prop `locale` y la
 * librería sólo incluye el diccionario `en`. La traducción hay que suministrarla
 * entera por `localization.variables`, así que aquí van las tres versiones.
 *
 * Se cubren `sign_in`, `sign_up` y `forgotten_password` porque son las vistas
 * alcanzables con `providers={[]}` y `magicLink={false}`. `magic_link`,
 * `update_password` y `verify_otp` no se traducen: son inalcanzables en LGI.
 */
const AUTH_VARS: Record<Lang, I18nVariables> = {
  es: {
    sign_in: {
      email_label: 'Correo',
      password_label: 'Contraseña',
      button_label: 'Entrar',
      email_input_placeholder: 'tu@email.com',
      password_input_placeholder: 'Tu contraseña',
      loading_button_label: 'Entrando…',
      link_text: '¿Ya tienes cuenta? Inicia sesión',
    },
    sign_up: {
      email_label: 'Correo',
      password_label: 'Contraseña',
      button_label: 'Crear cuenta',
      email_input_placeholder: 'tu@email.com',
      password_input_placeholder: 'Elige una contraseña',
      loading_button_label: 'Creando cuenta…',
      link_text: '¿Ya tienes cuenta? Inicia sesión',
      confirmation_text: 'Revisa tu correo para confirmar la cuenta',
    },
    forgotten_password: {
      email_label: 'Correo',
      button_label: 'Enviar instrucciones de recuperación',
      email_input_placeholder: 'tu@email.com',
      loading_button_label: 'Enviando…',
      link_text: 'Volver a entrar',
      confirmation_text: 'Revisa tu correo para restablecer la contraseña',
    },
  },
  en: {
    sign_in: {
      email_label: 'Email',
      password_label: 'Password',
      button_label: 'Sign in',
      email_input_placeholder: 'you@email.com',
      password_input_placeholder: 'Your password',
      loading_button_label: 'Signing in…',
      link_text: "Already have an account? Sign in",
    },
    sign_up: {
      email_label: 'Email',
      password_label: 'Password',
      button_label: 'Sign up',
      email_input_placeholder: 'you@email.com',
      password_input_placeholder: 'Choose a password',
      loading_button_label: 'Signing up…',
      link_text: "Already have an account? Sign in",
      confirmation_text: 'Check your email to confirm your account',
    },
    forgotten_password: {
      email_label: 'Email',
      button_label: 'Send reset instructions',
      email_input_placeholder: 'you@email.com',
      loading_button_label: 'Sending…',
      link_text: 'Back to sign in',
      confirmation_text: 'Check your email to reset your password',
    },
  },
  ru: {
    sign_in: {
      email_label: 'Эл. почта',
      password_label: 'Пароль',
      button_label: 'Войти',
      email_input_placeholder: 'вы@email.com',
      password_input_placeholder: 'Ваш пароль',
      loading_button_label: 'Вход…',
      link_text: 'Уже есть аккаунт? Войти',
    },
    sign_up: {
      email_label: 'Эл. почта',
      password_label: 'Пароль',
      button_label: 'Регистрация',
      email_input_placeholder: 'вы@email.com',
      password_input_placeholder: 'Придумайте пароль',
      loading_button_label: 'Регистрация…',
      link_text: 'Уже есть аккаунт? Войти',
      confirmation_text: 'Проверьте почту для подтверждения аккаунта',
    },
    forgotten_password: {
      email_label: 'Эл. почта',
      button_label: 'Отправить инструкции по восстановлению',
      email_input_placeholder: 'вы@email.com',
      loading_button_label: 'Отправка…',
      link_text: 'Вернуться ко входу',
      confirmation_text: 'Проверьте почту для сброса пароля',
    },
  },
}

export default function LoginPage() {
  const { lang } = useI18n()
  return (
    <div className="lgi-login-page"
      style={{
        maxWidth: 420,
        margin: '80px auto',
        padding: '0 20px',
        color: '#d7e4ee',
        position: 'relative',
        zIndex: 20000,
        width: '100%',
        minHeight: '100vh',
        boxSizing: 'border-box',
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
        /* 2026-10-04: LGI es EXCLUSIVAMENTE email/contraseña (`main.tsx`: "no se crean
           sesiones anónimas"). El enlace mágico rompía el acceso: Supabase lo envía al
           Site URL, que estaba en http://localhost:3000, así que quien lo abría desde
           su propio PC veía `otp_expired` / "Email link is invalid or has expired".
           Se desactiva para que el único camino sea contraseña. */
        magicLink={false}
        localization={{ variables: AUTH_VARS[lang] }}
      />
    </div>
  )
}