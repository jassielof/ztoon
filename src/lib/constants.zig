pub const list_item_marker: u8 = '-';
pub const list_item_prefix: []const u8 = "- ";

pub const comma: u8 = ',';
pub const colon: u8 = ':';
pub const space: u8 = ' ';
pub const pipe: u8 = '|';
pub const dot: u8 = '.';

pub const open_bracket: u8 = '[';
pub const close_bracket: u8 = ']';
pub const open_brace: u8 = '{';
pub const close_brace: u8 = '}';

pub const null_literal: []const u8 = "null";
pub const true_literal: []const u8 = "true";
pub const false_literal: []const u8 = "false";

pub const backslash: u8 = '\\';
pub const double_quote: u8 = '"';
pub const newline: u8 = '\n';
pub const carriage_return: u8 = '\r';
pub const tab: u8 = '\t';

pub const Delimiter = u8;
pub const DelimiterKey = enum { comma, tab, pipe };
pub const Delimiters = struct {
    pub const comma: Delimiter = ',';
    pub const tab: Delimiter = '\t';
    pub const pipe: Delimiter = '|';
};

pub const default_delimiter = Delimiters.comma;
