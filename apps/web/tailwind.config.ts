import type { Config } from 'tailwindcss'
import tailwindcssAnimate from 'tailwindcss-animate'

const config: Config = {
  darkMode: ['class'],
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}', './lib/**/*.{ts,tsx}'],
  theme: {
    container: {
      center: true,
      padding: '1.5rem',
      screens: { '2xl': '1400px' },
    },
    extend: {
      colors: {
        border: 'hsl(var(--border))',
        input: 'hsl(var(--input))',
        ring: 'hsl(var(--ring))',
        background: 'hsl(var(--background))',
        foreground: 'hsl(var(--foreground))',
        primary: {
          DEFAULT: 'hsl(var(--primary))',
          foreground: 'hsl(var(--primary-foreground))',
        },
        secondary: {
          DEFAULT: 'hsl(var(--secondary))',
          foreground: 'hsl(var(--secondary-foreground))',
        },
        muted: {
          DEFAULT: 'hsl(var(--muted))',
          foreground: 'hsl(var(--muted-foreground))',
        },
        accent: {
          DEFAULT: 'hsl(var(--accent))',
          foreground: 'hsl(var(--accent-foreground))',
        },
        destructive: {
          DEFAULT: 'hsl(var(--destructive))',
          foreground: 'hsl(var(--destructive-foreground))',
        },
        card: {
          DEFAULT: 'hsl(var(--card))',
          foreground: 'hsl(var(--card-foreground))',
        },
        // Статусы посещения/абонементов — из бейджей на макетах Stitch, не из ролей Material 3.
        success: {
          DEFAULT: 'hsl(var(--status-success))',
          bg: 'hsl(var(--status-success-bg))',
        },
        warning: {
          DEFAULT: 'hsl(var(--status-warning))',
          bg: 'hsl(var(--status-warning-bg))',
        },
        danger: {
          DEFAULT: 'hsl(var(--status-danger))',
          bg: 'hsl(var(--status-danger-bg))',
        },
        'status-neutral': {
          DEFAULT: 'hsl(var(--status-neutral))',
          bg: 'hsl(var(--status-neutral-bg))',
        },
        // «Болел» — временная заглушка, не из Stitch. globals.css, «Болел» рядом.
        info: {
          DEFAULT: 'hsl(var(--status-info))',
          bg: 'hsl(var(--status-info-bg))',
        },
      },
      borderRadius: {
        lg: 'var(--radius)',
        md: 'calc(var(--radius) - 2px)',
        sm: 'calc(var(--radius) - 4px)',
      },
      // Шкала отступов и типографика из docs/Design/DESIGN.md — доступны как
      // p-space-16, text-headline-lg и т.д. Ничего из дефолтной шкалы Tailwind
      // не переопределяет: существующие страницы этапов 0-3 не затронуты.
      spacing: {
        'space-2': '2px',
        'space-4': '4px',
        'space-6': '6px',
        'space-8': '8px',
        'space-12': '12px',
        'space-16': '16px',
        'space-20': '20px',
        'space-24': '24px',
        'space-32': '32px',
        'space-40': '40px',
        'sidebar-width': '240px',
        'sidebar-collapsed': '64px',
        'modal-max-width': '540px',
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
      },
      fontSize: {
        'headline-lg': ['24px', { lineHeight: '36px', letterSpacing: '-0.015em', fontWeight: '600' }],
        'headline-md': ['20px', { lineHeight: '30px', letterSpacing: '-0.01em', fontWeight: '600' }],
        'headline-sm': ['16px', { lineHeight: '24px', letterSpacing: '-0.005em', fontWeight: '600' }],
        'body-md-medium': ['14px', { lineHeight: '21px', letterSpacing: '0em', fontWeight: '500' }],
        'body-md': ['14px', { lineHeight: '21px', letterSpacing: '0em', fontWeight: '400' }],
        'body-sm': ['12px', { lineHeight: '18px', letterSpacing: '0.01em', fontWeight: '400' }],
        'label-sm': ['12px', { lineHeight: '18px', letterSpacing: '0.015em', fontWeight: '500' }],
        'label-xs': ['11px', { lineHeight: '16px', letterSpacing: '0.02em', fontWeight: '600' }],
      },
    },
  },
  plugins: [tailwindcssAnimate],
}

export default config
