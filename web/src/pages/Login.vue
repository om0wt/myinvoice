<script setup lang="ts">
import { ref, onMounted, nextTick } from 'vue'
import { useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'

const { t } = useI18n()
import AppShell from '@/components/layout/AppShell.vue'
import { useAuthStore } from '@/stores/auth'
import { useTurnstile } from '@/composables/useTurnstile'

const router = useRouter()
const auth = useAuthStore()

const email = ref('')
const password = ref('')
const totp = ref('')
const totpRequired = ref(false)
const error = ref<string>('')
const captchaRequired = ref(false)
const captchaSiteKey = ref('')
const captchaScriptUrl = ref('')

const turnstile = useTurnstile()
const turnstileEl = ref<HTMLElement | null>(null)

onMounted(async () => {
  await auth.fetchSetupStatus()
  if (auth.needsSetup) {
    router.replace('/setup')
    return
  }
  // Stale session detection: pokud uživatel přijde na /login s platnou cookie,
  // hodíme ho rovnou kam patří (`/` nebo `/setup-totp`). Bez toho by submit
  // formuláře probíhal v rozjetém stavu a UX by byl matoucí.
  const stillAuthed = await auth.refresh()
  if (stillAuthed) {
    router.replace(auth.mustSetupTotp ? '/setup-totp' : '/')
    return
  }
  if (auth.setupStatus?.captcha.provider === 'turnstile') {
    captchaSiteKey.value = auth.setupStatus.captcha.site_key
    captchaScriptUrl.value = auth.setupStatus.captcha.script_url
    captchaRequired.value = true
    // Render hned po mountu — captcha vždy aktivní, Cloudflare sám rozhodne.
    await nextTick()
    if (turnstileEl.value) {
      // Přiřaď DOM element do composable a render widget
      turnstile.containerRef.value = turnstileEl.value
      await turnstile.render(captchaSiteKey.value, captchaScriptUrl.value, 'login')
    }
  }
})

async function submit() {
  // Guard: pokud captcha vyžadovaná a token chybí, nepouštět request.
  // (button má `:disabled` ale Enter v inputu submitne form i s disabled buttonem
  //  → bez tohoto guardu by 1. pokus šel s prázdným tokenem → 400 captcha_failed.)
  if (captchaRequired.value && !turnstile.token.value) {
    error.value = t('auth.captcha_loading')
    return
  }
  error.value = ''
  try {
    await auth.login(email.value.trim(), password.value, turnstile.token.value || undefined, totp.value || undefined)
    router.push('/')
  } catch (e: any) {
    const code = e?.response?.data?.error?.code
    const msg  = e?.response?.data?.error?.message
    if (code === 'totp_required') {
      totpRequired.value = true
      error.value = ''
      // Token byl spotřebovaný 1. pokusem (heslo OK, čekáme na TOTP).
      // Reset → fresh token pro další pokus s TOTP kódem (jinak by 2. submit
      // šel s already-consumed tokenem → captcha_failed → user musí submit 2x).
      turnstile.reset()
    } else if (code === 'invalid_totp') {
      totp.value = ''
      error.value = msg || t('auth.totp_invalid')
      turnstile.reset()  // taky reset — token z předchozího pokusu už invalid
    } else if (code === 'captcha_required') {
      captchaRequired.value = true
      error.value = t('auth.captcha_required')
    } else if (code === 'captcha_failed') {
      turnstile.reset()
      error.value = t('auth.captcha_failed')
    } else if (code === 'too_many_attempts') {
      error.value = msg || t('auth.too_many_attempts')
    } else {
      error.value = msg || t('auth.login_failed')
      turnstile.reset()
    }
  }
}
</script>

<template>
  <AppShell :title="t('auth.login_title')">
    <div class="w-full max-w-sm">
      <div class="bg-white border border-neutral-200 rounded-lg shadow-sm p-6">
        <h2 class="text-xl font-semibold mb-1">{{ t('auth.login_title') }}</h2>
        <p class="text-sm text-neutral-500 mb-6">{{ t('auth.login_subtitle') }}</p>

        <form @submit.prevent="submit" class="space-y-4">
          <div>
            <label class="block text-sm font-medium text-neutral-700 mb-1">{{ t('auth.email') }}</label>
            <input
              v-model="email"
              type="email"
              autocomplete="email"
              required
              autofocus
              class="w-full h-10 px-3 border border-neutral-300 rounded-md focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 outline-none"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-neutral-700 mb-1">{{ t('auth.password') }}</label>
            <input
              v-model="password"
              type="password"
              autocomplete="current-password"
              required
              class="w-full h-10 px-3 border border-neutral-300 rounded-md focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 outline-none"
            />
          </div>

          <div v-if="totpRequired">
            <label class="block text-sm font-medium text-neutral-700 mb-1">{{ t('auth.totp_code') }}</label>
            <input
              v-model="totp"
              type="text"
              inputmode="numeric"
              autocomplete="one-time-code"
              maxlength="6"
              pattern="\d{6}"
              placeholder="000000"
              autofocus
              class="w-full h-10 px-3 border border-neutral-300 rounded-md font-mono text-lg tracking-widest text-center focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 outline-none"
            />
            <p class="text-xs text-neutral-500 mt-1">{{ t('auth.totp_hint') }}</p>
          </div>

          <!-- Turnstile container — vždy v DOM. Lokální template ref + watch
               v setup, který přiřadí do composable a vyrenderuje widget. -->
          <div v-show="captchaRequired" class="flex justify-center py-2">
            <div ref="turnstileEl"></div>
          </div>

          <div v-if="error" class="rounded-md bg-danger-50 border border-danger-500/40 px-3 py-2 text-sm text-danger-500">
            {{ error }}
          </div>

          <button
            type="submit"
            :disabled="auth.loading || (captchaRequired && !turnstile.token.value)"
            class="w-full h-10 bg-primary-600 hover:bg-primary-700 active:bg-primary-800 disabled:bg-neutral-300 disabled:cursor-not-allowed text-white font-medium rounded-md transition"
          >
            {{ auth.loading ? '…' : t('auth.login') }}
          </button>

          <div class="text-center pt-2">
            <router-link to="/forgot" class="text-sm text-primary-600 hover:underline">
              {{ t('auth.forgot') }}
            </router-link>
          </div>
        </form>
      </div>
    </div>
  </AppShell>
</template>
