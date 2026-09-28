'use client'

import { adminMessage } from '@/lib/admin-copy'

import { ChangeEvent, useCallback, useEffect, useMemo, useState } from 'react'
import { Image as ImageIcon, PauseCircle, PlayCircle, Plus, Save, Trash2, Upload } from 'lucide-react'
import { supabase } from '@/lib/supabase'

type BannerRow = {
  id: string
  title: string
  image_url: string
  position: string
  sort_order: number
  is_active: boolean
  status?: string | null
  metadata?: Record<string, unknown> | null
  created_at?: string | null
}

type Draft = {
  title: string
  title_en: string
  subtitle: string
  subtitle_en: string
  cta: string
  cta_en: string
  image_url: string
  sort_order: number
}

const blankDraft: Draft = { title: '', title_en: '', subtitle: '', subtitle_en: '', cta: 'Reservar ahora', cta_en: 'Book now', image_url: '', sort_order: 100 }
const localPreview: Record<string, string> = {
  'wissa://banner/home-cleaning': '/banners/home-cleaning.jpg',
  'wissa://banner/exterior': '/banners/exterior.jpg',
  'wissa://banner/plumbing': '/banners/plumbing.jpg',
}

const BANNER_WIDTH = 1200
const BANNER_HEIGHT = 600
const BANNER_RATIO = BANNER_WIDTH / BANNER_HEIGHT

async function readBannerDimensions(file: File) {
  const bitmap = await createImageBitmap(file)
  const dimensions = { width: bitmap.width, height: bitmap.height }
  bitmap.close()
  return dimensions
}

export default function BannersPage() {
  const [rows, setRows] = useState<BannerRow[]>([])
  const [draft, setDraft] = useState<Draft>(blankDraft)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [message, setMessage] = useState('')

  const activeCount = useMemo(() => rows.filter((row) => row.is_active && row.status !== 'paused').length, [rows])

  const load = useCallback(async () => {
    setLoading(true)
    const { data, error } = await supabase
      .from('banners')
      .select('id,title,image_url,position,sort_order,is_active,status,metadata,created_at')
      .eq('position', 'home')
      .order('sort_order', { ascending: true })
      .order('created_at', { ascending: false })
    if (error) setMessage(error.message)
    else setRows((data || []) as BannerRow[])
    setLoading(false)
  }, [])

  useEffect(() => { void load() }, [load])

  const uploadImage = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0]
    if (!file) return
    if (file.size > 5 * 1024 * 1024) {
      setMessage('La imagen supera 5 MB.')
      return
    }
    try {
      const { width, height } = await readBannerDimensions(file)
      const ratio = width / Math.max(1, height)
      if (width < 1000 || height < 500) {
        setMessage(`Imagen muy pequeña (${width}×${height}). Usa mínimo 1000×500 px; recomendado 1200×600 px.`)
        event.target.value = ''
        return
      }
      if (Math.abs(ratio - BANNER_RATIO) > 0.12) {
        setMessage(`Formato no recomendado (${width}×${height}). Usa relación 2:1, idealmente 1200×600 px.`)
        event.target.value = ''
        return
      }
    } catch {
      setMessage('No pudimos validar las dimensiones de la imagen.')
      event.target.value = ''
      return
    }
    setSaving(true)
    setMessage('')
    try {
      const extension = file.name.split('.').pop()?.toLowerCase() || 'jpg'
      const path = `home/${Date.now()}-${Math.random().toString(36).slice(2)}.${extension}`
      const { error } = await supabase.storage.from('wissa-banners').upload(path, file, { upsert: false, contentType: file.type || undefined })
      if (error) throw error
      const { data } = supabase.storage.from('wissa-banners').getPublicUrl(path)
      setDraft((previous) => ({ ...previous, image_url: data.publicUrl }))
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'No se pudo subir la imagen.')
    } finally {
      setSaving(false)
      event.target.value = ''
    }
  }

  const save = async () => {
    if (!draft.title.trim() || !draft.image_url.trim()) {
      setMessage('Título e imagen son obligatorios.')
      return
    }
    const editing = rows.find((row) => row.id === editingId)
    const willBeActive = editing ? editing.is_active && editing.status !== 'paused' : true
    if (!editingId && activeCount >= 5) {
      setMessage('Ya existen 5 banners activos. Pausa uno antes de agregar otro.')
      return
    }
    if (editingId && willBeActive && activeCount > 5) {
      setMessage('Solo pueden existir 5 banners activos.')
      return
    }
    setSaving(true)
    setMessage('')
    const payload = {
      title: draft.title.trim(),
      image_url: draft.image_url.trim(),
      position: 'home',
      sort_order: Number(draft.sort_order || 100),
      is_active: editing?.is_active ?? true,
      status: editing?.status || 'active',
      metadata: { title_en: draft.title_en.trim(), subtitle: draft.subtitle.trim(), subtitle_en: draft.subtitle_en.trim(), cta: draft.cta.trim(), cta_en: draft.cta_en.trim() },
      updated_at: new Date().toISOString(),
    }
    const result = editingId
      ? await supabase.from('banners').update(payload).eq('id', editingId)
      : await supabase.from('banners').insert(payload)
    if (result.error) setMessage(result.error.message)
    else {
      setDraft(blankDraft)
      setEditingId(null)
      setMessage('Banner guardado.')
      await load()
    }
    setSaving(false)
  }

  const edit = (row: BannerRow) => {
    const meta = row.metadata || {}
    setEditingId(row.id)
    setDraft({
      title: row.title,
      title_en: String(meta.title_en || ''),
      subtitle: String(meta.subtitle || ''),
      subtitle_en: String(meta.subtitle_en || ''),
      cta: String(meta.cta || 'Reservar ahora'),
      cta_en: String(meta.cta_en || 'Book now'),
      image_url: row.image_url,
      sort_order: row.sort_order || 100,
    })
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  const toggle = async (row: BannerRow) => {
    const nextActive = !(row.is_active && row.status !== 'paused')
    if (nextActive && activeCount >= 5) {
      setMessage('Máximo 5 banners activos.')
      return
    }
    setSaving(true)
    const { error } = await supabase
      .from('banners')
      .update({ is_active: nextActive, status: nextActive ? 'active' : 'paused', updated_at: new Date().toISOString() })
      .eq('id', row.id)
    if (error) setMessage(error.message)
    await load()
    setSaving(false)
  }

  const remove = async (row: BannerRow) => {
    if (!window.confirm(`¿Eliminar el banner “${row.title}”?`)) return
    setSaving(true)
    const { error } = await supabase.from('banners').delete().eq('id', row.id)
    if (error) setMessage(error.message)
    if (editingId === row.id) { setEditingId(null); setDraft(blankDraft) }
    await load()
    setSaving(false)
  }

  const preview = (url: string) => localPreview[url] || url

  return (
    <div style={{ display: 'grid', gap: 18 }}>
      <section className="card" style={{ padding: 24 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 16, flexWrap: 'wrap' }}>
          <div>
            <div className="eyebrow">Home del cliente</div>
            <h2 style={{ margin: '5px 0' }}>Banners promocionales</h2>
            <p className="subtitle" style={{ margin: 0 }}>Hasta 5 imágenes activas · formato estándar 2:1 · recomendado 1200 × 600 px · mínimo 1000 × 500 px.</p>
          </div>
          <div className="notice" style={{ minWidth: 190 }}><strong>{activeCount}/5 activos</strong><br />Pausa, edita o elimina sin publicar una nueva app.</div>
        </div>
      </section>

      <section className="card" style={{ padding: 18 }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(190px,1fr))', gap: 10 }}>
          <div className="notice"><strong>Medida estándar</strong><br />1200 × 600 px · relación 2:1</div>
          <div className="notice"><strong>Zona segura</strong><br />Mantén texto/logos dentro del 70% central.</div>
          <div className="notice"><strong>Rotación en la app</strong><br />Automática cada 5.5 s + swipe y puntos manuales.</div>
        </div>
      </section>

      <section className="card" style={{ padding: 22 }}>
        <h3 style={{ marginTop: 0 }}>{editingId ? 'Editar banner' : 'Agregar banner'}</h3>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(220px,1fr))', gap: 12 }}>
          <label className="field"><span className="label">Título ES</span><input className="input" value={draft.title} onChange={(e) => setDraft({ ...draft, title: e.target.value })} placeholder="Tu hogar, siempre impecable" /></label>
          <label className="field"><span className="label">Title EN</span><input className="input" value={draft.title_en} onChange={(e) => setDraft({ ...draft, title_en: e.target.value })} placeholder="Your home, always spotless" /></label>
          <label className="field"><span className="label">Orden</span><input className="input" type="number" min="1" value={draft.sort_order} onChange={(e) => setDraft({ ...draft, sort_order: Number(e.target.value || 100) })} /></label>
          <label className="field"><span className="label">Texto secundario ES</span><input className="input" value={draft.subtitle} onChange={(e) => setDraft({ ...draft, subtitle: e.target.value })} placeholder="Servicios profesionales para tu hogar" /></label>
          <label className="field"><span className="label">Texto secundario en inglés</span><input className="input" value={draft.subtitle_en} onChange={(e) => setDraft({ ...draft, subtitle_en: e.target.value })} placeholder="Professional services for your home" /></label>
          <label className="field"><span className="label">CTA ES</span><input className="input" value={draft.cta} onChange={(e) => setDraft({ ...draft, cta: e.target.value })} placeholder="Reservar ahora" /></label>
          <label className="field"><span className="label">CTA EN</span><input className="input" value={draft.cta_en} onChange={(e) => setDraft({ ...draft, cta_en: e.target.value })} placeholder="Book now" /></label>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr auto', gap: 12, alignItems: 'end', marginTop: 12 }}>
          <label className="field"><span className="label">URL de imagen</span><input className="input" value={draft.image_url} onChange={(e) => setDraft({ ...draft, image_url: e.target.value })} placeholder="https://..." /></label>
          <label className="btn btn-soft" style={{ cursor: 'pointer', marginBottom: 0 }}><Upload size={17} />Subir imagen<input type="file" accept="image/jpeg,image/png,image/webp" onChange={uploadImage} hidden /></label>
        </div>
        {draft.image_url ? <div style={{ marginTop: 14 }}><img src={preview(draft.image_url)} alt="Vista previa" style={{ width: '100%', maxWidth: 650, aspectRatio: '2 / 1', objectFit: 'cover', borderRadius: 18, border: '1px solid var(--line)' }} /><div className="subtitle" style={{ marginTop: 6 }}>Vista previa 2:1 · 1200×600 recomendado</div></div> : null}
        <div style={{ display: 'flex', gap: 10, marginTop: 14 }}>
          <button className="btn btn-primary" onClick={save} disabled={saving}><Save size={17} />{editingId ? 'Guardar cambios' : 'Agregar banner'}</button>
          {editingId ? <button className="btn btn-soft" onClick={() => { setEditingId(null); setDraft(blankDraft) }}>Cancelar</button> : null}
        </div>
        {message ? <div className="notice" style={{ marginTop: 12 }}>{adminMessage(message)}</div> : null}
      </section>

      <section className="card" style={{ padding: 22 }}>
        <h3 style={{ marginTop: 0 }}>Banners del Home</h3>
        {loading ? <p className="subtitle">Cargando...</p> : null}
        <div style={{ display: 'grid', gap: 12 }}>
          {rows.map((row) => {
            const active = row.is_active && row.status !== 'paused'
            const meta = row.metadata || {}
            return (
              <div key={row.id} style={{ display: 'grid', gridTemplateColumns: '160px minmax(220px,1fr) auto', gap: 14, alignItems: 'center', border: '1px solid var(--line)', borderRadius: 18, padding: 12 }}>
                <img src={preview(row.image_url)} alt={row.title} style={{ width: 160, height: 82, objectFit: 'cover', borderRadius: 12 }} />
                <div><strong>{row.title}</strong><div className="subtitle" style={{ marginTop: 4 }}>{String(meta.subtitle || '') || 'Sin texto secundario'} · Orden {row.sort_order}</div><div style={{ marginTop: 5, fontWeight: 800, color: active ? '#16a34a' : '#b45309' }}>{active ? 'Activo' : 'Pausado'}</div></div>
                <div style={{ display: 'flex', gap: 7, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
                  <button className="btn btn-soft btn-small" onClick={() => edit(row)}><ImageIcon size={15} />Editar</button>
                  <button className="btn btn-soft btn-small" onClick={() => toggle(row)}>{active ? <PauseCircle size={15} /> : <PlayCircle size={15} />}{active ? 'Pausar' : 'Activar'}</button>
                  <button className="btn btn-danger btn-small" onClick={() => remove(row)}><Trash2 size={15} />Eliminar</button>
                </div>
              </div>
            )
          })}
          {!loading && !rows.length ? <div className="notice">No hay banners. Puedes subir el primero ahora.</div> : null}
        </div>
      </section>
    </div>
  )
}
