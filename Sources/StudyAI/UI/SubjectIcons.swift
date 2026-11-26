import SwiftData
import SwiftUI

/// Iconos para las asignaturas, pensados para una carrera de logística (y lo común a cualquier carrera).
/// Si la asignatura no tiene icono elegido, se adivina por palabras del nombre.
enum SubjectIcons {
    struct Item: Identifiable {
        let symbol: String, label: String, keys: [String]
        var id: String { symbol }
    }

    static let all: [Item] = [
        .init(symbol: "shippingbox.fill", label: "Logística", keys: ["logist"]),
        .init(symbol: "box.truck.fill", label: "Transporte por carretera", keys: ["transport", "carretera", "camion", "flota"]),
        .init(symbol: "airplane", label: "Transporte aéreo", keys: ["aere", "avion", "aeropuert", "carga aerea"]),
        .init(symbol: "ferry.fill", label: "Transporte marítimo", keys: ["marit", "puerto", "naval", "contenedor"]),
        .init(symbol: "train.side.front.car", label: "Ferrocarril e intermodal", keys: ["ferro", "tren", "intermodal", "multimodal"]),
        .init(symbol: "building.2.fill", label: "Almacenes", keys: ["almac", "bodega", "nave", "warehouse"]),
        .init(symbol: "cube.box.fill", label: "Inventarios", keys: ["invent", "stock", "existencia"]),
        .init(symbol: "barcode", label: "Trazabilidad", keys: ["trazab", "codigo", "rfid", "etiquet"]),
        .init(symbol: "arrow.triangle.2.circlepath", label: "Cadena de suministro", keys: ["cadena", "suministro", "supply", "scm"]),
        .init(symbol: "shippingbox.and.arrow.backward.fill", label: "Logística inversa", keys: ["invers", "devoluc", "retorno"]),
        .init(symbol: "cart.fill", label: "Compras y aprovisionamiento", keys: ["compra", "aprovision", "proveedor", "procure"]),
        .init(symbol: "storefront.fill", label: "Comercio y distribución", keys: ["comerc", "retail", "venta", "ecommerce", "e-commerce"]),
        .init(symbol: "globe.europe.africa.fill", label: "Comercio internacional", keys: ["internac", "global", "export", "import"]),
        .init(symbol: "doc.text.fill", label: "Aduanas y documentación", keys: ["aduan", "document", "incoterm", "fiscal"]),
        .init(symbol: "map.fill", label: "Rutas y distribución", keys: ["ruta", "distrib", "geograf", "ultima milla"]),
        .init(symbol: "signpost.right.fill", label: "Planificación", keys: ["planif", "plan "]),
        .init(symbol: "chart.line.uptrend.xyaxis", label: "Previsión de demanda", keys: ["demanda", "prevision", "forecast"]),
        .init(symbol: "chart.bar.fill", label: "Estadística y datos", keys: ["estadist", "datos", "analit", "probabil"]),
        .init(symbol: "function", label: "Matemáticas", keys: ["matemat", "calculo", "algebra"]),
        .init(symbol: "sum", label: "Investigación operativa", keys: ["operativa", "optimiz", "modelos"]),
        .init(symbol: "eurosign.circle.fill", label: "Finanzas y costes", keys: ["finan", "contab", "coste", "presupuest"]),
        .init(symbol: "banknote.fill", label: "Economía", keys: ["econom", "microecon", "macroecon"]),
        .init(symbol: "person.3.fill", label: "Personas y equipos", keys: ["human", "rrhh", "persona", "equipo", "liderazgo", "organizac"]),
        .init(symbol: "gearshape.2.fill", label: "Operaciones y producción", keys: ["operacion", "produc", "proceso", "fabric"]),
        .init(symbol: "wrench.and.screwdriver.fill", label: "Mantenimiento", keys: ["manten", "ingenier"]),
        .init(symbol: "leaf.fill", label: "Sostenibilidad", keys: ["sosten", "ambient", "verde", "huella"]),
        .init(symbol: "shield.lefthalf.filled", label: "Seguridad y riesgos", keys: ["segur", "riesgo", "prevenc"]),
        .init(symbol: "building.columns.fill", label: "Derecho", keys: ["derech", "legal", "jurid", "normativ", "contrat"]),
        .init(symbol: "cpu.fill", label: "Tecnología y sistemas", keys: ["tecnolog", "sistema", "erp", "digital", "automat"]),
        .init(symbol: "desktopcomputer", label: "Informática", keys: ["informat", "software", "ofimat", "program"]),
        .init(symbol: "point.3.connected.trianglepath.dotted", label: "Redes logísticas", keys: ["redes", "network", "nodo"]),
        .init(symbol: "checklist", label: "Calidad", keys: ["calidad", "lean", "iso", "sigma", "mejora"]),
        .init(symbol: "megaphone.fill", label: "Marketing", keys: ["market", "publicid"]),
        .init(symbol: "briefcase.fill", label: "Empresa y gestión", keys: ["empres", "gestion", "direccion", "administr", "negocio"]),
        .init(symbol: "bubble.left.and.bubble.right.fill", label: "Comunicación y negociación", keys: ["comunic", "negociac"]),
        .init(symbol: "character.book.closed.fill", label: "Idiomas", keys: ["ingles", "idioma", "english", "frances", "aleman"]),
        .init(symbol: "lightbulb.fill", label: "Innovación", keys: ["innova", "emprend", "proyecto"]),
        .init(symbol: "target", label: "Estrategia", keys: ["estrateg", "objetivo"]),
        .init(symbol: "graduationcap.fill", label: "TFG y prácticas", keys: ["tfg", "trabajo fin", "practica", "tfm"]),
        .init(symbol: "books.vertical.fill", label: "General", keys: []),
    ]

    static let fallback = "books.vertical.fill"

    /// El icono que mejor encaja con el nombre (sin tildes ni mayúsculas), o el genérico.
    static func guess(_ name: String) -> String {
        let n = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) + " "
        return all.first { $0.keys.contains { n.contains($0) } }?.symbol ?? fallback
    }

    static func symbol(for subject: Subject) -> String { subject.icon ?? guess(subject.name) }
}

/// Crear o editar una asignatura: nombre e icono a la vista, con el icono sugerido según escribes.
struct SubjectEditor: View {
    let subject: Subject?
    let onDone: (Subject?) -> Void
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var icon: String?
    @FocusState private var focused: Bool

    private var shown: String { icon ?? SubjectIcons.guess(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                SubjectBadge(symbol: shown, name: name, size: 64)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: shown)
                VStack(alignment: .leading, spacing: 4) {
                    Text(subject == nil ? "Nueva asignatura" : "Editar asignatura").font(.title2.weight(.bold))
                    TextField("Nombre", text: $name, prompt: Text("Por ejemplo, Gestión de almacenes"))
                        .textFieldStyle(.roundedBorder).font(.system(size: 15))
                        .focused($focused)
                        .onSubmit(save)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Icono").font(.headline)
                    Spacer()
                    if icon != nil {
                        Button("Sugerir por el nombre") { icon = nil }.buttonStyle(.borderless).font(.callout)
                    }
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 8), count: 8), spacing: 8) {
                        ForEach(SubjectIcons.all) { item in
                            let selected = item.symbol == shown
                            Button { icon = item.symbol } label: {
                                Image(systemName: item.symbol).font(.system(size: 20))
                                    .foregroundStyle(selected ? .white : Theme.ink)
                                    .frame(width: 52, height: 52)
                                    .background(selected ? AnyShapeStyle(Theme.speakerColor(name)) : AnyShapeStyle(Theme.subtle),
                                                in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .help(item.label)
                        }
                    }
                }
                .frame(height: 290)
                Text(SubjectIcons.all.first { $0.symbol == shown }?.label ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(subject == nil ? "Crear" : "Guardar", action: save)
                    .buttonStyle(ProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            name = subject?.name ?? ""
            icon = subject?.icon
            focused = true
        }
    }

    private func save() {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let s = subject ?? Subject(name: clean)
        if subject == nil { context.insert(s) }
        s.name = clean
        s.icon = icon
        try? context.save()
        onDone(s)
    }
}

/// Insignia de color con el icono (el color sale del nombre: siempre el mismo).
struct SubjectBadge: View {
    let symbol: String
    let name: String?
    var size: CGFloat = 44

    var body: some View {
        let color = name.map { Theme.speakerColor($0) } ?? .gray
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.28))
            .shadow(color: color.opacity(0.35), radius: 6, y: 3)
    }
}
