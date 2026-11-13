//
//  CrewParts.swift
//  leanring-buddy
//
//  Every hat, antenna, set of eyes and extra, as the design's own markup in the figure's 48-unit box. C is the part's
//  colour.
//

import ClickyCore
import Foundation

enum CrewParts {
    private static let heart = "M0 2.3C-2.7.5-3.5-.8-3.5-2a1.75 1.75 0 0 1 3.5-.6A1.75 1.75 0 0 1 3.5-2c0 1.2-.8 2.5-3.5 4.3z"

    static func hat(_ hat: CrewLook.Hat) -> String {
        switch hat {
        case .none: return ""
        case .hardhat: return ##"<path d="M7.5 15.5a16.5 12 0 0 1 33 0z" fill="C"/><path d="M5 15.6h38" stroke="C" stroke-width="3.2" stroke-linecap="round"/><path d="M24 4.2v10.6M17 6.4l1.6 8.6M31 6.4l-1.6 8.6" stroke="rgba(0,0,0,.25)" stroke-width="1.3" stroke-linecap="round"/>"##
        case .beret: return ##"<ellipse cx="20.5" cy="9.2" rx="13.5" ry="4.6" transform="rotate(-14 20.5 9.2)" fill="C"/><circle cx="19.5" cy="4.6" r="1.7" fill="C"/>"##
        case .cap: return ##"<path d="M9 15.2a15 11 0 0 1 30 0z" fill="C"/><path d="M27 13.6h14.2a2 2 0 0 1 0 3.2H27z" fill="C"/><path d="M9 15.2h30" stroke="rgba(0,0,0,.25)" stroke-width="1.2"/><circle cx="24" cy="4.4" r="1.5" fill="rgba(0,0,0,.25)"/>"##
        case .beanie: return ##"<path d="M8.6 14.5a15.4 12 0 0 1 30.8 0z" fill="C"/><rect x="7.4" y="11.6" width="33.2" height="5" rx="2.2" fill="C"/><path d="M10 14.1h28" stroke="rgba(0,0,0,.2)" stroke-width="1" stroke-dasharray="1.2 1.6"/><circle class="pom" cx="24" cy="2.4" r="2.8" fill="C"/>"##
        case .tophat: return ##"<rect x="15" y="-2" width="18" height="13.5" rx="1.6" fill="C"/><rect x="10" y="10.6" width="28" height="3.2" rx="1.6" fill="C"/><rect x="15" y="7.6" width="18" height="2.4" fill="rgba(255,255,255,.25)"/>"##
        case .crown: return ##"<path d="M13.5 13.5 14.5 3l5.2 5 4.3-6.4 4.3 6.4 5.2-5 1 10.5z" fill="C" stroke="rgba(0,0,0,.2)" stroke-width=".8" stroke-linejoin="round"/><circle cx="24" cy="9.6" r="1.3" fill="rgba(255,255,255,.7)"/>"##
        case .headset: return ##"<path d="M8.5 17A15.5 14 0 0 1 39.5 17" stroke="C" stroke-width="2.6" fill="none" stroke-linecap="round"/><rect x="2.8" y="16.5" width="5.6" height="11" rx="2.6" fill="C"/><rect x="39.6" y="16.5" width="5.6" height="11" rx="2.6" fill="C"/><path d="M5.6 27.5q1 6.8 9.4 7.6" stroke="C" stroke-width="1.6" fill="none" stroke-linecap="round"/><circle cx="15.6" cy="35.1" r="1.7" fill="C"/>"##
        }
    }

    static func antenna(_ antenna: CrewLook.Antenna) -> String {
        switch antenna {
        case .none: return ""
        case .ball: return ##"<path d="M24 8V2.6" stroke="#8a8a8f" stroke-width="1.6" stroke-linecap="round"/><circle class="tip" cx="24" cy="1.8" r="2.3" fill="C"/>"##
        case .twin: return ##"<path d="M16.5 9 13.6 3.2M31.5 9l2.9-5.8" stroke="#8a8a8f" stroke-width="1.5" stroke-linecap="round"/><circle class="tip" cx="13.2" cy="2.6" r="1.9" fill="C"/><circle class="tip" cx="34.8" cy="2.6" r="1.9" fill="C"/>"##
        case .dish: return ##"<path d="M31 8.5 34.5 4" stroke="#8a8a8f" stroke-width="1.5" stroke-linecap="round"/><path d="M31.2 1.2a5.2 5.2 0 0 0 7.6 6.9z" fill="#c9c9cf"/><circle class="tip" cx="35" cy="4.6" r="1.3" fill="C"/>"##
        case .flag: return ##"<path d="M24 8V0.8" stroke="#8a8a8f" stroke-width="1.5" stroke-linecap="round"/><path class="flag" d="M24.6 1h7.6l-2.2 2.5 2.2 2.5h-7.6z" fill="C"/>"##
        case .bolt: return ##"<path d="M24 8V5" stroke="#8a8a8f" stroke-width="1.6" stroke-linecap="round"/><path class="tip" d="M25.6-2.6 20.4 3.4h3.3L22.4 8l5.6-6.6h-3.3z" fill="C"/>"##
        case .heart: return ##"<path d="M24 8V4.6" stroke="#8a8a8f" stroke-width="1.6" stroke-linecap="round"/><path class="tip" transform="translate(24 1.6) scale(1.05)" d="\##(heart)" fill="C"/>"##
        case .cursor: return ##"<path class="arrow" d="M33.5 .8 42.6 8l-3.9.8 2.3 4.1-1.9 1.1-2.3-4.1-2.9 2.6z" fill="C" stroke="#0b0b0b" stroke-width=".8" stroke-linejoin="round"/>"##
        }
    }

    static func eyes(_ eyes: CrewLook.Eyes) -> String {
        switch eyes {
        case .pill: return ##"<rect x="16.45" y="18.5" width="4.6" height="6" rx="2.3"/><rect x="26.95" y="18.5" width="4.6" height="6" rx="2.3"/>"##
        case .round: return ##"<circle cx="18.75" cy="21.5" r="2.9"/><circle cx="29.25" cy="21.5" r="2.9"/>"##
        case .pixel: return ##"<rect x="16.55" y="19.3" width="4.4" height="4.4" rx=".5"/><rect x="27.05" y="19.3" width="4.4" height="4.4" rx=".5"/>"##
        case .visor: return ##"<rect x="15.2" y="19.7" width="17.6" height="3.8" rx="1.9"/>"##
        case .hearts: return ##"<path transform="translate(18.75 21.4)" d="\##(heart)"/><path transform="translate(29.25 21.4)" d="\##(heart)"/>"##
        }
    }

    static func extra(_ extra: CrewLook.Extra) -> String {
        switch extra {
        case .none: return ""
        case .tie: return ##"<path d="M22.4 39.4h3.2l1 2.2-2.6 6-2.6-6z" fill="C"/>"##
        case .bowtie: return ##"<path d="M18.6 38.2l5 2.4-5 2.4zM29.4 38.2l-5 2.4 5 2.4z" fill="C"/><circle cx="24" cy="40.6" r="1.5" fill="C"/>"##
        case .scarf: return ##"<path d="M12.5 38q11.5 4.2 23 0v3.4q-11.5 4.4-23 0z" fill="C"/><rect x="28" y="40" width="4" height="7.5" rx="1.4" fill="C" transform="rotate(-8 30 40)"/>"##
        case .badge: return ##"<circle cx="38" cy="9" r="5.4" fill="C"/><path d="m35.6 9 1.7 1.7 3.2-3.3" stroke="#0b0b0b" stroke-width="1.6" fill="none" stroke-linecap="round" stroke-linejoin="round"/>"##
        case .pencil: return ##"<g transform="rotate(32 39 12)"><rect x="37.3" y="1.5" width="3.6" height="15.5" rx="1.1" fill="C"/><rect x="37.3" y="1.5" width="3.6" height="2.6" rx="1" fill="#f3f3f3"/><path d="M37.3 17h3.6l-1.8 3.2z" fill="#f1d2a1"/></g>"##
        case .glasses: return ##"<g stroke="C" stroke-width="1.5" fill="none"><circle cx="18.75" cy="21.5" r="4.6"/><circle cx="29.25" cy="21.5" r="4.6"/><path d="M23.35 21.5h1.3"/></g>"##
        }
    }

    static let shoulders = "M11 48c0-6.2 5.8-9.4 13-9.4s13 3.2 13 9.4z"
    static let shut = "M16.6 22h4.3M27.1 22h4.3"
    static let happy = "M16.4 23q2.35-3.2 4.7 0M26.9 23q2.35-3.2 4.7 0"
    static let alert = "M18.75 18.4v3.6M29.25 18.4v3.6M18.75 25v.1M29.25 25v.1"
}
