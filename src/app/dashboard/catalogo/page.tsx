'use client'

import { adminMessage } from '@/lib/admin-copy'

import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '@/lib/supabase'

type CatalogItem = {
  id: string
  kind: 'extra' | 'product'
  category_name: string | null
  name_es: string
  name_en: string
  description_es: string | null
  description_en: string | null
  price: number
  active: boolean
  sort_order: number | null
  kit_tier?: 'basic' | 'premium' | 'custom' | null
}

type ServiceField = {
  id: string
  category_name: string
  field_key: string
  label: string
  label_en: string | null
  field_type: 'text' | 'textarea' | 'number' | 'select'
  options: string[] | null
  options_en: string[] | null
  is_required: boolean
  is_active: boolean
  sort_order: number
  applies_to: string | null
}

type CategoryRow = { name: string | null; sort_order: number | null }

const splitOptions = (value: string) => value.split('\n').map((item) => item.trim()).filter(Boolean)
const joinOptions = (value?: string[] | null) => (Array.isArray(value) ? value.join('\n') : '')
const slugKey = (value: string) => value.trim().toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '')
const normalize = (value?: string | null) => String(value || '').trim().toLocaleLowerCase('es').normalize('NFD').replace(/[\u0300-\u036f]/g, '')

const categoryHints: Record<string, { extras: string; kits: string; note?: string }> = {
  limpieza: {
    extras: 'Ej.: nevera, horno, aspirado de sofá u otros trabajos adicionales.',
    kits: 'Ej.: paños, guantes, esponjas, limpiavidrios o desengrasante. Solo agrégalos cuando tengas el precio real.',
  },
  'limpieza de exteriores': {
    extras: 'Ej.: tratamiento de manchas, lavado puntual o atención adicional definida por Wissa.',
    kits: 'Ej.: guantes, cepillo exterior, bolsas o detergente exterior. No se crean automáticamente.',
  },
  plomeria: {
    extras: 'Plomería no utiliza extras.',
    kits: 'Plomería no utiliza kits ni materiales dentro del cobro de Wissa.',
    note: 'Solo diagnóstico + traslado real + USD 2 de plataforma + ITBMS 7%.',
  },
}

export default function CatalogPage() {
  const [items, setItems] = useState<CatalogItem[]>([])
  const [fields, setFields] = useState<ServiceField[]>([])
  const [serviceCategories, setServiceCategories] = useState<CategoryRow[]>([])
  const [selectedCategory, setSelectedCategory] = useState('')
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)
  const [draft, setDraft] = useState({ kind: 'product' as 'extra' | 'product', category_name: '', name_es: '', name_en: '', description_es: '', description_en: '', price: '', sort_order: '100' })
  const [fieldDraft, setFieldDraft] = useState({ category_name: '', field_key: '', label: '', label_en: '', field_type: 'select' as ServiceField['field_type'], options: '', options_en: '', is_required: false, sort_order: '100' })

  const load = useCallback(async () => {
    setError('')
    const [catalogResult, fieldsResult, categoriesResult] = await Promise.all([
      supabase.from('booking_catalog').select('*').order('category_name').order('sort_order').order('created_at'),
      supabase.from('service_category_fields').select('*').eq('applies_to', 'booking').order('category_name').order('sort_order'),
      supabase.from('service_categories').select('name,sort_order').eq('is_active', true).order('sort_order'),
    ])
    if (catalogResult.error) throw catalogResult.error
    if (fieldsResult.error) throw fieldsResult.error
    if (categoriesResult.error) throw categoriesResult.error
    setItems((catalogResult.data || []) as CatalogItem[])
    setFields((fieldsResult.data || []) as ServiceField[])
    setServiceCategories((categoriesResult.data || []) as CategoryRow[])
  }, [])

  useEffect(() => { void load().catch((reason) => setError(reason instanceof Error ? reason.message : String(reason))) }, [load])

  const categories = useMemo(() => {
    const values: string[] = []
    const add = (value?: string | null) => {
      const clean = String(value || '').trim()
      if (clean && !values.some((entry) => normalize(entry) === normalize(clean))) values.push(clean)
    }
    serviceCategories.forEach((row) => add(row.name))
    fields.forEach((field) => add(field.category_name))
    items.forEach((item) => add(item.category_name))
    return values
  }, [fields, items, serviceCategories])

  useEffect(() => {
    if (!selectedCategory && categories.length) setSelectedCategory(categories[0])
  }, [categories, selectedCategory])

  useEffect(() => {
    if (!selectedCategory) return
    setDraft((current) => ({ ...current, category_name: current.category_name || selectedCategory }))
    setFieldDraft((current) => ({ ...current, category_name: current.category_name || selectedCategory }))
  }, [selectedCategory])

  const currentItems = useMemo(() => items.filter((item) => normalize(item.category_name) === normalize(selectedCategory)), [items, selectedCategory])
  const uncategorizedItems = useMemo(() => items.filter((item) => !String(item.category_name || '').trim()), [items])
  const currentFields = useMemo(() => fields.filter((field) => normalize(field.category_name) === normalize(selectedCategory)), [fields, selectedCategory])
  const extras = currentItems.filter((item) => item.kind === 'extra')
  const products = currentItems.filter((item) => item.kind === 'product')
  const hint = categoryHints[normalize(selectedCategory)]
  const plumbingSelected = normalize(selectedCategory) === 'plomeria'

  async function saveCatalog(item?: CatalogItem) {
    if (busy) return
    setBusy(true); setError(''); setNotice('')
    try {
      if (plumbingSelected) throw new Error('Plomería no permite extras, kits ni materiales dentro de Wissa.')
      const source = item || draft
      const price = Number(source.price)
      const sortOrder = Number(source.sort_order ?? 100)
      const category = String(source.category_name || selectedCategory || '').trim()
      if (!category) throw new Error('Selecciona una categoría antes de agregar el producto.')
      if (!source.name_es.trim() || !source.name_en.trim() || !Number.isFinite(price) || price < 0) throw new Error('Completa ambos idiomas y un precio USD válido.')
      if (!Number.isFinite(sortOrder)) throw new Error('El orden debe ser numérico.')
      const payload = {
        kind: source.kind,
        category_name: category,
        name_es: source.name_es.trim(),
        name_en: source.name_en.trim(),
        description_es: String(source.description_es || '').trim() || null,
        description_en: String(source.description_en || '').trim() || null,
        price,
        sort_order: sortOrder,
        active: item ? item.active : true,
        kit_tier: null,
      }
      const result = item ? await supabase.from('booking_catalog').update(payload).eq('id', item.id) : await supabase.from('booking_catalog').insert(payload)
      if (result.error) throw result.error
      if (!item) setDraft({ kind: 'product', category_name: category, name_es: '', name_en: '', description_es: '', description_en: '', price: '', sort_order: String(sortOrder + 10) })
      setNotice(item ? 'Elemento actualizado.' : 'Elemento agregado a la categoría.')
      await load()
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)) } finally { setBusy(false) }
  }

  async function deleteCatalog(item: CatalogItem) {
    if (!window.confirm(`¿Eliminar “${item.name_es}”? Las reservas históricas conservan su desglose guardado.`)) return
    setBusy(true); setError(''); setNotice('')
    try {
      const result = await supabase.from('booking_catalog').delete().eq('id', item.id)
      if (result.error) throw result.error
      setNotice('Elemento eliminado del catálogo.')
      await load()
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)) } finally { setBusy(false) }
  }

  async function saveField(field?: ServiceField) {
    if (busy) return
    setBusy(true); setError(''); setNotice('')
    try {
      const source = field ? {
        ...field,
        optionsText: joinOptions(field.options),
        optionsEnText: joinOptions(field.options_en),
      } : {
        ...fieldDraft,
        optionsText: fieldDraft.options,
        optionsEnText: fieldDraft.options_en,
        is_active: true,
      }
      const category = String(source.category_name || selectedCategory || '').trim()
      const label = source.label.trim()
      const key = (source.field_key || slugKey(label)).trim()
      if (!category || !label || !key) throw new Error('Categoría, nombre y clave son obligatorios.')
      const fieldType = source.field_type
      const payload = {
        category_name: category,
        field_key: key,
        label,
        label_en: source.label_en?.trim() || null,
        field_type: fieldType,
        options: fieldType === 'select' ? splitOptions(source.optionsText) : [],
        options_en: fieldType === 'select' ? splitOptions(source.optionsEnText) : [],
        is_required: Boolean(source.is_required),
        is_active: Boolean(source.is_active),
        sort_order: Number(source.sort_order || 100),
        applies_to: 'booking',
      }
      if (!Number.isFinite(payload.sort_order)) throw new Error('El orden debe ser numérico.')
      const result = field ? await supabase.from('service_category_fields').update(payload).eq('id', field.id) : await supabase.from('service_category_fields').insert(payload)
      if (result.error) throw result.error
      if (!field) setFieldDraft({ category_name: category, field_key: '', label: '', label_en: '', field_type: 'select', options: '', options_en: '', is_required: false, sort_order: String(Number(source.sort_order || 100) + 10) })
      setNotice(field ? 'Detalle actualizado.' : 'Detalle agregado al servicio.')
      await load()
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)) } finally { setBusy(false) }
  }

  async function deleteField(field: ServiceField) {
    if (!window.confirm(`¿Eliminar el campo “${field.label}” de ${field.category_name}?`)) return
    setBusy(true); setError(''); setNotice('')
    try {
      const result = await supabase.from('service_category_fields').delete().eq('id', field.id)
      if (result.error) throw result.error
      setNotice('Detalle eliminado.')
      await load()
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)) } finally { setBusy(false) }
  }

  const updateItem = (index: number, patch: Partial<CatalogItem>) => {
    const target = currentItems[index]
    if (!target) return
    setItems((rows) => rows.map((row) => row.id === target.id ? { ...row, ...patch } : row))
  }

  return (
    <section style={{ display: 'grid', gap: 22 }}>
      <div className="card" style={{ padding: 24 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 16, alignItems: 'flex-start', flexWrap: 'wrap' }}>
          <div>
            <p style={{ margin: 0, color: '#2563eb', fontSize: 12, fontWeight: 900, letterSpacing: 1.5, textTransform: 'uppercase' }}>Catálogo por categoría</p>
            <h1 style={{ margin: '6px 0 8px' }}>Extras, kits y detalles del servicio</h1>
            <p style={{ margin: 0, maxWidth: 850 }}>Cada categoría tiene su propio catálogo. Un producto de Limpieza ya no aparecerá en Plomería ni en Exteriores. Los kits son productos opcionales administrables; no existen niveles Básico/Premium.</p>
          </div>
          <div style={{ border: '1px solid #bfdbfe', background: '#eff6ff', borderRadius: 14, padding: '10px 14px', fontWeight: 800, color: '#1e40af' }}>80/20 solo en servicio y extras · kit 100% Wissa</div>
        </div>

        {error ? <p role="alert" style={{ color: '#b91c1c', fontWeight: 700 }}>{adminMessage(error)}</p> : null}
        {notice ? <p role="status" style={{ color: '#047857', fontWeight: 700 }}>{notice}</p> : null}

        <div style={{ display: 'flex', gap: 9, flexWrap: 'wrap', marginTop: 22 }}>
          {categories.map((category) => {
            const active = normalize(category) === normalize(selectedCategory)
            const itemCount = items.filter((item) => normalize(item.category_name) === normalize(category)).length
            const fieldCount = fields.filter((field) => normalize(field.category_name) === normalize(category) && field.is_active).length
            return <button key={category} type="button" onClick={() => { setSelectedCategory(category); setDraft((d) => ({ ...d, category_name: category })); setFieldDraft((d) => ({ ...d, category_name: category })) }} style={{ borderRadius: 999, padding: '10px 14px', border: active ? '1px solid #2563eb' : '1px solid #cbd5e1', background: active ? '#2563eb' : '#fff', color: active ? '#fff' : '#172033', fontWeight: 850 }}>{category} · {itemCount} catálogo · {fieldCount} campos</button>
          })}
        </div>

        {uncategorizedItems.length ? <div style={{ marginTop: 16, padding: 14, borderRadius: 14, border: '1px solid #fcd34d', background: '#fffbeb', color: '#854d0e' }}><strong>{uncategorizedItems.length} elemento(s) sin categoría.</strong> No se mostrarán en las reservas hasta que los clasifiques. Esto evita que un producto aparezca en una categoría incorrecta.</div> : null}
      </div>

      <div className="card" style={{ padding: 24 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
          <div>
            <h2 style={{ margin: 0 }}>Catálogo · {selectedCategory || 'Selecciona una categoría'}</h2>
            <p style={{ margin: '6px 0 0' }}>Administra los extras y materiales opcionales de cada categoría.</p>
          </div>
        </div>

        {plumbingSelected ? <div className="notice" style={{ marginTop: 16 }}><strong>Plomería: solo diagnóstico.</strong> No se administran extras, kits ni materiales para esta categoría. El cliente paga el diagnóstico con las reglas financieras vigentes de Wissa. La reparación posterior se coordina directamente con quien ofrece.</div> : null}

        {hint ? <div style={{ marginTop: 16, display: plumbingSelected ? 'none' : 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(260px,1fr))', gap: 10 }}>
          <div style={{ border: '1px solid #dbeafe', borderRadius: 14, padding: 13, background: '#f8fbff' }}><strong>Extras sugeridos</strong><div style={{ marginTop: 4, color: '#64748b' }}>{hint.extras}</div></div>
          <div style={{ border: '1px solid #dbeafe', borderRadius: 14, padding: 13, background: '#f8fbff' }}><strong>Kits/materiales sugeridos</strong><div style={{ marginTop: 4, color: '#64748b' }}>{hint.kits}</div>{hint.note ? <div style={{ marginTop: 6, color: '#92400e', fontWeight: 700 }}>{hint.note}</div> : null}</div>
        </div> : null}

        <form onSubmit={(event) => { event.preventDefault(); void saveCatalog() }} style={{ display: plumbingSelected ? 'none' : 'grid', gap: 12, marginBlock: 22, padding: 18, border: '1px solid #dbe4ee', borderRadius: 16, background: '#fbfdff' }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(170px,1fr))', gap: 12 }}>
            <select aria-label="Categoría" value={draft.category_name || selectedCategory} onChange={(event) => setDraft({ ...draft, category_name: event.target.value })}>{categories.map((category) => <option key={category} value={category}>{category}</option>)}</select>
            <select aria-label="Tipo" value={draft.kind} onChange={(event) => setDraft({ ...draft, kind: event.target.value as CatalogItem['kind'] })}><option value="product">Kit / producto opcional</option><option value="extra">Extra del servicio</option></select>
            <input required aria-label="Nombre español" placeholder="Nombre en español" value={draft.name_es} onChange={(event) => setDraft({ ...draft, name_es: event.target.value })} />
            <input required aria-label="Nombre inglés" placeholder="English name" value={draft.name_en} onChange={(event) => setDraft({ ...draft, name_en: event.target.value })} />
            <input required aria-label="Precio USD" placeholder="USD" type="number" min="0" step="0.01" value={draft.price} onChange={(event) => setDraft({ ...draft, price: event.target.value })} />
            <input aria-label="Orden" placeholder="Orden" type="number" value={draft.sort_order} onChange={(event) => setDraft({ ...draft, sort_order: event.target.value })} />
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}><input placeholder="Descripción corta (opcional)" value={draft.description_es} onChange={(event) => setDraft({ ...draft, description_es: event.target.value })} /><input placeholder="Short description (optional)" value={draft.description_en} onChange={(event) => setDraft({ ...draft, description_en: event.target.value })} /></div>
          <button disabled={busy} style={{ width: 'fit-content' }}>Agregar a {selectedCategory || 'categoría'}</button>
        </form>

        <div style={{ display: plumbingSelected ? 'none' : 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(380px,1fr))', gap: 16 }}>
          {([['extra', 'Extras', extras], ['product', 'Kits y materiales', products]] as const).map(([kind, title, rows]) => <div key={kind} style={{ border: '1px solid #dbe4ee', borderRadius: 18, padding: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, alignItems: 'center', marginBottom: 12 }}><h3 style={{ margin: 0 }}>{title}</h3><span style={{ borderRadius: 999, background: '#eff6ff', color: '#1d4ed8', padding: '5px 9px', fontSize: 12, fontWeight: 850 }}>{rows.length}</span></div>
            <div style={{ display: 'grid', gap: 10 }}>
              {rows.length === 0 ? <div style={{ padding: 18, textAlign: 'center', color: '#64748b', background: '#f8fafc', borderRadius: 12 }}>No hay elementos configurados.</div> : rows.map((item) => {
                const index = currentItems.findIndex((entry) => entry.id === item.id)
                return <details key={item.id} style={{ border: '1px solid #e2e8f0', borderRadius: 13, padding: 12, background: '#fff' }}>
                  <summary style={{ cursor: 'pointer', fontWeight: 850 }}>{item.name_es} · USD {Number(item.price).toFixed(2)} · {item.active ? 'Activo' : 'Inactivo'}</summary>
                  <div style={{ display: 'grid', gap: 10, marginTop: 12 }}>
                    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 9 }}>
                      <select value={item.category_name || ''} onChange={(event) => updateItem(index, { category_name: event.target.value })}>{categories.map((category) => <option key={category} value={category}>{category}</option>)}</select>
                      <select value={item.kind} onChange={(event) => updateItem(index, { kind: event.target.value as CatalogItem['kind'], kit_tier: null })}><option value="extra">Extra</option><option value="product">Kit / producto</option></select>
                      <input value={item.name_es} onChange={(event) => updateItem(index, { name_es: event.target.value })} />
                      <input value={item.name_en} onChange={(event) => updateItem(index, { name_en: event.target.value })} />
                      <input type="number" min="0" step="0.01" value={item.price} onChange={(event) => updateItem(index, { price: Number(event.target.value) })} />
                      <input type="number" value={item.sort_order ?? 100} onChange={(event) => updateItem(index, { sort_order: Number(event.target.value) })} />
                    </div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 9 }}><input placeholder="Descripción ES" value={item.description_es || ''} onChange={(event) => updateItem(index, { description_es: event.target.value })} /><input placeholder="Description EN" value={item.description_en || ''} onChange={(event) => updateItem(index, { description_en: event.target.value })} /></div>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}><label><input type="checkbox" checked={item.active} onChange={(event) => updateItem(index, { active: event.target.checked })} /> Activo</label><button disabled={busy} onClick={() => void saveCatalog(item)}>Guardar</button><button type="button" disabled={busy} onClick={() => void deleteCatalog(item)} style={{ background: '#fff', color: '#b91c1c', border: '1px solid #fecaca' }}>Eliminar</button></div>
                  </div>
                </details>
              })}
            </div>
          </div>)}
        </div>
      </div>

      <div className="card" style={{ padding: 24 }}>
        <h2 style={{ marginTop: 0 }}>Detalles del servicio · {selectedCategory}</h2>
        <p>Solo ves los campos de la categoría seleccionada. Puedes agregar, traducir, ordenar, desactivar o eliminar sin modificar el código de la app.</p>
        <form onSubmit={(event) => { event.preventDefault(); void saveField() }} style={{ display: 'grid', gap: 12, marginBlock: 20, padding: 18, border: '1px solid #dbe4ee', borderRadius: 16, background: '#fbfdff' }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(180px,1fr))', gap: 12 }}>
            <select required value={fieldDraft.category_name || selectedCategory} onChange={(event) => setFieldDraft({ ...fieldDraft, category_name: event.target.value })}>{categories.map((category) => <option key={category} value={category}>{category}</option>)}</select>
            <input placeholder="Clave (opcional)" value={fieldDraft.field_key} onChange={(event) => setFieldDraft({ ...fieldDraft, field_key: event.target.value })} />
            <select value={fieldDraft.field_type} onChange={(event) => setFieldDraft({ ...fieldDraft, field_type: event.target.value as ServiceField['field_type'] })}><option value="select">Selección</option><option value="text">Texto</option><option value="textarea">Texto largo</option><option value="number">Número</option></select>
            <input type="number" placeholder="Orden" value={fieldDraft.sort_order} onChange={(event) => setFieldDraft({ ...fieldDraft, sort_order: event.target.value })} />
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}><input required placeholder="Etiqueta español" value={fieldDraft.label} onChange={(event) => setFieldDraft({ ...fieldDraft, label: event.target.value })} /><input placeholder="English label" value={fieldDraft.label_en} onChange={(event) => setFieldDraft({ ...fieldDraft, label_en: event.target.value })} /></div>
          {fieldDraft.field_type === 'select' ? <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}><textarea rows={5} placeholder={'Opciones español, una por línea'} value={fieldDraft.options} onChange={(event) => setFieldDraft({ ...fieldDraft, options: event.target.value })} /><textarea rows={5} placeholder={'English options, one per line'} value={fieldDraft.options_en} onChange={(event) => setFieldDraft({ ...fieldDraft, options_en: event.target.value })} /></div> : null}
          <label style={{ display: 'flex', gap: 8, alignItems: 'center' }}><input type="checkbox" checked={fieldDraft.is_required} onChange={(event) => setFieldDraft({ ...fieldDraft, is_required: event.target.checked })} /> Obligatorio</label>
          <button disabled={busy} style={{ width: 'fit-content' }}>Agregar detalle</button>
        </form>

        <div style={{ display: 'grid', gap: 10 }}>
          {currentFields.map((field) => {
            const index = fields.findIndex((row) => row.id === field.id)
            return <details key={field.id} open={false} style={{ border: '1px solid #dbe4ee', borderRadius: 12, padding: 14 }}>
              <summary style={{ cursor: 'pointer', fontWeight: 800 }}>{field.label} · {field.is_active ? 'Activo' : 'Inactivo'}</summary>
              <div style={{ display: 'grid', gap: 10, marginTop: 14 }}>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(170px,1fr))', gap: 10 }}>
                  <select value={field.category_name} onChange={(event) => setFields(fields.map((row, i) => i === index ? { ...row, category_name: event.target.value } : row))}>{categories.map((category) => <option key={category} value={category}>{category}</option>)}</select>
                  <input value={field.field_key} onChange={(event) => setFields(fields.map((row, i) => i === index ? { ...row, field_key: event.target.value } : row))} />
                  <select value={field.field_type} onChange={(event) => setFields(fields.map((row, i) => i === index ? { ...row, field_type: event.target.value as ServiceField['field_type'] } : row))}><option value="select">Selección</option><option value="text">Texto</option><option value="textarea">Texto largo</option><option value="number">Número</option></select>
                  <input type="number" value={field.sort_order} onChange={(event) => setFields(fields.map((row, i) => i === index ? { ...row, sort_order: Number(event.target.value) } : row))} />
                </div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}><input value={field.label} onChange={(event) => setFields(fields.map((row, i) => i === index ? { ...row, label: event.target.value } : row))} /><input placeholder="English label" value={field.label_en || ''} onChange={(event) => setFields(fields.map((row, i) => i === index ? { ...row, label_en: event.target.value } : row))} /></div>
                {field.field_type === 'select' ? <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}><textarea rows={4} value={joinOptions(field.options)} onChange={(event) => setFields(fields.map((row, i) => i === index ? { ...row, options: splitOptions(event.target.value) } : row))} /><textarea rows={4} value={joinOptions(field.options_en)} onChange={(event) => setFields(fields.map((row, i) => i === index ? { ...row, options_en: splitOptions(event.target.value) } : row))} /></div> : null}
                <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', alignItems: 'center' }}><label><input type="checkbox" checked={field.is_required} onChange={(event) => setFields(fields.map((row, i) => i === index ? { ...row, is_required: event.target.checked } : row))} /> Obligatorio</label><label><input type="checkbox" checked={field.is_active} onChange={(event) => setFields(fields.map((row, i) => i === index ? { ...row, is_active: event.target.checked } : row))} /> Activo</label><button disabled={busy} onClick={() => void saveField(field)}>Guardar detalle</button><button type="button" disabled={busy} onClick={() => void deleteField(field)} style={{ background: '#fff', color: '#b91c1c', border: '1px solid #fecaca' }}>Eliminar</button></div>
              </div>
            </details>
          })}
        </div>
      </div>
    </section>
  )
}
