//! Lab-scanner looks: reading a developed film the way a Frontier or Noritsu
//! sensor does, through ISO 5-3 Status M.
pub mod density;

/// One click of an operator's density or colour key, in log10 density: about
/// 1/12 stop.
pub const KEY_STEP_LOG10: f64 = 0.025;
