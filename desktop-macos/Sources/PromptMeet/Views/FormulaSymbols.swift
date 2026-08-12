import Foundation

/// Unicode tables shared by the strict formula parser, the plain-text
/// fallback converter, and the renderer.
enum FormulaSymbols {
    /// Unicode glyph for a known LaTeX command, or nil when the command is not a symbol.
    static func glyph(forCommand name: String) -> String? {
        symbols[name]
    }

    /// Multi-character upright operator names (sin, cos, lim, ...).
    static func operatorName(forCommand name: String) -> String? {
        operatorNames[name]
    }

    /// Large operator glyphs rendered with stacked or side limits.
    static func largeOperatorGlyph(forCommand name: String) -> String? {
        largeOperators[name]
    }

    /// Accent marks drawn above a base node.
    static func accentMark(forCommand name: String) -> String? {
        accents[name]
    }

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ε", "varepsilon": "ϵ", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "ϕ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "partial": "∂", "nabla": "∇", "in": "∈", "notin": "∉",
        "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "sqcup": "⊔", "sqcap": "⊓",
        "vee": "∨", "wedge": "∧", "oplus": "⊕", "otimes": "⊗",
        "ominus": "⊖", "odot": "⊙", "div": "÷", "times": "×",
        "cdot": "⋅", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆",
        "circ": "∘", "bullet": "∙", "diamond": "⋄",
        "leq": "≤", "ge": "≥", "geq": "≥", "le": "≤",
        "neq": "≠", "ne": "≠", "equiv": "≡", "sim": "∼",
        "approx": "≈", "propto": "∝", "ll": "≪", "gg": "≫",
        "infty": "∞", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
        "and": "∧", "or": "∨",
        "to": "→", "rightarrow": "→", "leftarrow": "←",
        "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "mapsto": "↦",
        "longrightarrow": "⟶", "longleftarrow": "⟵",
        "longleftrightarrow": "⟷", "uparrow": "↑", "downarrow": "↓",
        "updownarrow": "↕", "Uparrow": "⇑", "Downarrow": "⇓",
        "Updownarrow": "⇕",
        "hbar": "ℏ", "ell": "ℓ", "wp": "℘", "Re": "ℜ", "Im": "ℑ",
        "aleph": "ℵ", "prime": "′", "degree": "°", "angle": "∠",
        "perp": "⊥", "parallel": "∥", "mid": "∣", "nmid": "∤",
        "models": "⊨", "vdash": "⊢", "dashv": "⊣", "vDash": "⊩",
        "triangleleft": "◁", "triangleright": "▷",
        "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "dagger": "†", "ddagger": "‡", "S": "§",
        "surd": "√", "checkmark": "✓"
    ]

    private static let largeOperators: [String: String] = [
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "sum": "∑", "prod": "∏", "coprod": "∐",
        "bigcup": "⋃", "bigcap": "⋂", "bigvee": "⋁", "bigwedge": "⋀",
        "bigoplus": "⨁", "bigotimes": "⨂", "bigodot": "⨀", "bigsqcup": "⨆"
    ]

    private static let operatorNames: [String: String] = [
        "arccos": "arccos", "arcsin": "arcsin", "arctan": "arctan",
        "arg": "arg", "cos": "cos", "cosh": "cosh", "cot": "cot",
        "coth": "coth", "csc": "csc", "deg": "deg", "det": "det",
        "dim": "dim", "exp": "exp", "gcd": "gcd", "hom": "hom",
        "inf": "inf", "ker": "ker", "lg": "lg", "lim": "lim",
        "liminf": "lim inf", "limsup": "lim sup", "ln": "ln",
        "log": "log", "max": "max", "min": "min", "Pr": "Pr",
        "sec": "sec", "sin": "sin", "sinh": "sinh", "sup": "sup",
        "tan": "tan", "tanh": "tanh"
    ]

    private static let accents: [String: String] = [
        "bar": "\u{0305}", "hat": "^", "vec": "→", "dot": "\u{0307}",
        "ddot": "\u{0308}", "tilde": "~", "widehat": "^", "overline": "\u{0305}"
    ]
}
