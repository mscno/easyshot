// Easyshot web: the <easyshot-player> Rocket component and two small page behaviors.
// Imports the runtime by the exact URL the layout loads, so the page has one Datastar.
import { rocket } from '/static/datastar-rocket-1.0.4.js'

const clock = (ms) => {
  const s = Math.max(0, Math.floor(ms / 1000))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const ss = String(s % 60).padStart(2, '0')
  return h ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`
}

// <easyshot-player> wraps the server-rendered <video> (light DOM, no render function, so
// the native player and its no-JavaScript fallback stay as rendered). It publishes the
// playback position to inputs marked [data-player-time] / [data-player-clock] (comment and
// reaction forms), seeks when anything marked [data-seek-ms] is clicked, fills the
// transcript list from the captions track and highlights the current line.
//
// Live patches never touch the <video> (data-ignore-morph keeps playback going), so a
// poster or transcript published later arrives as the host's data-poster / data-captions
// attributes, which this applies to the video: poster, and a <track> it adds.
rocket('easyshot-player', {
  mode: 'light',
  onFirstRender({ host, cleanup }) {
    const video = host.querySelector('video')
    if (!video) return
    const strip = host.querySelector('.markers')
    let lines = []
    let active = null
    let trackEl = null

    const highlight = (ms) => {
      const line = lines.find((l) => ms >= l.start && ms < l.end) ?? null
      if (line === active) return
      active?.el.classList.remove('active')
      active = line
      if (line) {
        line.el.classList.add('active')
        if (!video.paused) line.el.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
      }
    }

    const publish = () => {
      const ms = Math.round(video.currentTime * 1000)
      for (const el of document.querySelectorAll('[data-player-time]')) el.value = String(ms)
      for (const el of document.querySelectorAll('[data-player-clock]')) el.textContent = clock(ms)
      if (strip && video.duration) strip.style.setProperty('--progress', `${(video.currentTime / video.duration) * 100}%`)
      highlight(ms)
    }

    const seek = (ms) => {
      video.currentTime = ms / 1000
      video.play().catch(() => {})
    }

    const onClick = (evt) => {
      const target = evt.target.closest?.('[data-seek-ms]')
      if (target) {
        evt.preventDefault()
        seek(Number(target.dataset.seekMs))
        return
      }
      if (strip && evt.target === strip && video.duration) {
        const r = strip.getBoundingClientRect()
        seek(((evt.clientX - r.left) / r.width) * video.duration * 1000)
      }
    }

    const buildTranscript = (track) => {
      // Looked up each time: the transcript card may be shown after the player started.
      const list = document.querySelector('[data-transcript]')
      if (!list || !track.cues) return
      lines = [...track.cues].map((cue) => {
        const li = document.createElement('li')
        const button = document.createElement('button')
        button.type = 'button'
        button.dataset.seekMs = String(Math.round(cue.startTime * 1000))
        const time = document.createElement('span')
        time.className = 'stamp'
        time.textContent = clock(cue.startTime * 1000)
        const text = document.createElement('span')
        text.textContent = cue.text
        button.append(time, text)
        li.append(button)
        return { el: li, start: cue.startTime * 1000, end: cue.endTime * 1000 }
      })
      list.replaceChildren(...lines.map((l) => l.el))
      if (!lines.length) list.innerHTML = '<li class="muted">No speech was transcribed.</li>'
    }

    const attachTrack = (el) => {
      trackEl = el
      const track = el.track
      // Load cues without drawing captions; viewers can still turn captions on.
      if (track.mode === 'disabled') track.mode = 'hidden'
      const onLoad = () => buildTranscript(track)
      el.addEventListener('load', onLoad)
      cleanup(() => el.removeEventListener('load', onLoad))
      if (el.readyState === 2) onLoad()
    }

    const sync = () => {
      const poster = host.dataset.poster
      if (poster && video.getAttribute('poster') !== poster) video.setAttribute('poster', poster)
      if (!poster && video.hasAttribute('poster')) video.removeAttribute('poster')
      const captions = host.dataset.captions
      if (captions && !trackEl) {
        const el = document.createElement('track')
        el.kind = 'captions'
        el.srclang = 'en'
        el.label = 'Transcript'
        el.src = captions
        video.append(el)
        attachTrack(el)
      } else if (!captions && trackEl) {
        trackEl.remove()
        trackEl = null
        lines = []
        active = null
      }
    }

    const existing = video.querySelector('track')
    if (existing) attachTrack(existing)
    sync()
    const observer = new MutationObserver(sync)
    observer.observe(host, { attributes: true, attributeFilter: ['data-poster', 'data-captions'] })
    cleanup(() => observer.disconnect())

    video.addEventListener('timeupdate', publish)
    video.addEventListener('seeked', publish)
    document.addEventListener('click', onClick)
    cleanup(() => {
      video.removeEventListener('timeupdate', publish)
      video.removeEventListener('seeked', publish)
      document.removeEventListener('click', onClick)
    })
    publish()
  },
})

// Copy buttons: [data-copy="text"].
document.addEventListener('click', async (evt) => {
  const button = evt.target.closest?.('[data-copy]')
  if (!button) return
  const label = button.textContent
  try {
    await navigator.clipboard.writeText(button.dataset.copy)
    button.textContent = 'Copied'
  } catch {
    button.textContent = 'Press ⌘C'
    window.prompt('Copy this link', button.dataset.copy)
  }
  setTimeout(() => {
    button.textContent = label
  }, 1500)
})
