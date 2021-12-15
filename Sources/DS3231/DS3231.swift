//=== HCSR04.swift --------------------------------------------------------===//
//
// Copyright (c) MadMachine Limited
// Licensed under MIT License
//
// Authors: Ines Zhou
// Created: 11/12/2021
// Updated: 11/12/2021
//
// See https://madmachine.io for more information
//
//===----------------------------------------------------------------------===//

import SwiftIO

/// The library for DS3231 real time clock.
///
/// You can read the time information including year, month, day, hour,
/// minute, second from it. It comes with a battery so the time will always
/// keep updated. Once powered off, the RTC needs a calibration. The RTC also
/// has two alarms and you can set them to alarm at a specified time.
final public class DS3231 {
    private let i2c: I2C
    private let address: UInt8

    private var daysInMonth: [UInt8] = [
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    ]


    /// Initialize the RTC.
    /// - Parameters:
    ///   - i2c: **REQUIRED** The I2C interface the RTC connects to.
    ///   - address: **OPTIONAL** The sensor's address. It has a default value.
    public init(_ i2c: I2C, _ address: UInt8 = 0x68) {
        self.i2c = i2c
        self.address = address
    }

    /// Set current time to calibrate the RTC.
    ///
    /// If the RTC has stopped due to power off, it will be set to the
    /// specified time. If not, the time will not be reset by default.
    /// If you want to make it mandatory, you can set the parameter
    /// `update` to `true`.
    /// - Parameters:
    ///   - time: Current time from year to second.
    ///   - update: Whether to update the time.
    public func setTime(_ time: Time, update: Bool = false) {
        let reading = lostPower()
        if let reading = reading {
            if reading || update {
                let data = [
                    binToBcd(time.second), binToBcd(time.minute),
                    binToBcd(time.hour), binToBcd(time.dayOfWeek),
                    binToBcd(time.day), binToBcd(time.month),
                    binToBcd(UInt8(time.year - 2000))]

                writeData(Register.second, data)

                let value = readRegister(Register.status)
                if let value = value {
                    // Set OSF bit to 0, which means the RTC hasn't stopped
                    // so far after the time is set.
                    writeRegister(Register.status, value & 0b0111_1111)
                } else {
                    print("set time error")
                }
            }
        }
    }


    /// Read current time.
    /// - Returns: The time info in a struct.
    public func readCurrent() -> Time? {
        i2c.write(Register.second.rawValue, to: address)
        let data = i2c.read(count: 7, from: address)

        if data.count != 7 {
            print("readCurrent error")
            return nil
        } else {
            let year = UInt16(bcdToBin(data[6])) + 2000
            // Make sure the bit for century is 0.
            let month = bcdToBin(data[5] & 0b0111_1111)
            let day = bcdToBin(data[4])
            let dayOfWeek = bcdToBin(data[3])
            let hour = bcdToBin(data[2])
            let minute = bcdToBin(data[1])
            let second = bcdToBin(data[0])

            let time = Time(
                year: year, month: month, day: day, hour: hour,
                minute: minute, second: second, dayOfWeek: dayOfWeek)
            return time
        }


    }

    /// Read current temperature.
    /// - Returns: Temperature in Celsius.
    public func readTemperature() -> Float? {
        i2c.write(Register.temperature.rawValue, to: address)
        let data = i2c.read(count: 2, from: address)

        if data.count != 2 {
            print("readTemperature error")
            return nil
        } else {
            let temperature = Float(data[0]) + Float(data[1] >> 6) * 0.25
            return temperature
        }
    }


    /// Set alarm1 at a specific time. The time can be decided by second,
    /// minute, hour, day or any combination of them.
    ///
    /// The alarm works only once. If you want it to happen continuously, you
    /// need to clear it manually when it is activated.
    ///
    /// Make sure the mode corresponds to the time you set. For example,
    /// you set the alarm to alert at 1m20s, like 1m20s, 1h1m20s... the mode
    /// should be `.minute`.
    ///
    /// - Parameters:
    ///   - day: The day from 1 to 31 in a month.
    ///   - dayOfWeek: The day from 1 to 7 in a week.
    ///   - hour: The hour from 0 to 23 in a day,
    ///   - minute: The minute from 0 to 59 in an hour.
    ///   - second: The second from 0 to 59 in a minute.
    ///   - mode: The alarm1 mode.
    public func setAlarm1(
        day: UInt8 = 0, dayOfWeek: UInt8 = 0, hour: UInt8 = 0,
        minute: UInt8 = 0, second: UInt8 = 0, mode: Alarm1Mode
    ) {
        clearAlarm(1)
        clearAlarm(2)
        disableAlarm(2)
        setSqwMode(SqwMode.off)

        // Bit7 of second.
        let A1M1 = (mode.rawValue & 0b0001) << 7
        // Bit7 of minute.
        let A1M2 = (mode.rawValue & 0b0010) << 6
        // Bit7 of hour.
        let A1M3 = (mode.rawValue & 0b0100) << 5
        // Bit7 of day.
        let A1M4 = (mode.rawValue & 0b1000) << 4
        // Bit6 of day to decide it is day of month or day of week.
        let DYDT = (mode.rawValue & 0b1_0000) << 2

        let second = binToBcd(second) | A1M1
        let minute = binToBcd(minute) | A1M2
        let hour = binToBcd(hour) | A1M3

        var day: UInt8 = 0
        if DYDT == 0 {
            day = binToBcd(day) | A1M4 | DYDT
        } else {
            day = binToBcd(dayOfWeek) | A1M4 | DYDT
        }

        let future = [second, minute, hour, day]
        writeData(Register.alarm1, future)

        let data = readRegister(Register.control)
        if let value = data {
            if value & 0b0100 != 0 {
                writeRegister(Register.control, value | 0b01)
            }
        } else {
            print("set alarm1 error")
        }
    }

    /// Set alarm2 at a specific time. The time can be decided by minute,
    /// hour, day or any combination of them.
    ///
    /// The alarm works only once. If you want it to happen continuously, you
    /// need to clear it manually when it is activated.
    ///
    /// Make sure the mode corresponds to the time you set. For example,
    /// you set the alarm to alert at 2m, like 2m, 1h2m... the mode
    /// should be `.minute`.
    ///
    /// - Parameters:
    ///   - day: The day from 1 to 31 in a month.
    ///   - dayOfWeek: The day from 1 to 7 in a week.
    ///   - hour: The hour from 0 to 23 in a day.
    ///   - minute: The minute from 0 to 59 in an hour.
    ///   - mode: The alarm2 mode.
    public func setAlarm2(
        day: UInt8 = 0, dayOfWeek: UInt8 = 0, hour: UInt8 = 0,
        minute: UInt8 = 0, mode: Alarm2Mode
    ) {
        clearAlarm(1)
        clearAlarm(2)
        disableAlarm(1)
        setSqwMode(SqwMode.off)

        let A2M2 = (mode.rawValue & 0b0001) << 7
        let A2M3 = (mode.rawValue & 0b0010) << 6
        let A2M4 = (mode.rawValue & 0b0100) << 5
        let DYDT = (mode.rawValue & 0b1000) << 3

        let minute = binToBcd(minute) | A2M2
        let hour = binToBcd(hour) | A2M3
        var day: UInt8 = 0

        if DYDT == 0 {
            day = binToBcd(day) | A2M4 | DYDT
        } else {
            day = binToBcd(dayOfWeek) | A2M4 | DYDT
        }

        let future = [minute, hour, day]
        writeData(Register.alarm2, future)

        let data = readRegister(Register.control)
        if let value = data {
            if value & 0b0100 != 0 {
                writeRegister(Register.control, value | 0b10)
            }
        } else {
            print("set alarm2 error")
        }
    }

    /// The alarm1 will activate after a specified time interval. The time
    /// can be specified as day, hour, minute, second or any combination of them.
    /// - Parameters:
    ///   - day: The days of time interval.
    ///   - hour: The hour of time interval.
    ///   - minute: The minutes of time interval.
    ///   - second: The seconds of time interval.
    ///   - mode: The alarm1 mode.
    public func setTimer1(
        day: UInt8 = 0, hour: UInt8 = 0, minute: UInt8 = 0,
        second: UInt8 = 0, mode: Alarm1Mode
    ) {
        let current = readCurrent()
        if let current = current {
            let futureSecond = (current.second + second) % 60
            let futureMinute = (current.minute + minute) % 60 +
                (current.second + second) / 60
            let futureHour = (current.hour + hour) % 24 +
                (current.minute + minute) / 60

            if current.year % 4 == 0 {
                daysInMonth[1] = 29
            }

            let totalDays: UInt8 = daysInMonth[Int(current.month - 1)]

            let futureDay = (current.day + day) % totalDays +
                (current.hour + hour) / 24

            setAlarm1(day: futureDay, hour: futureHour, minute: futureMinute,
                      second: futureSecond, mode: mode)
        }
    }

    /// The alarm2 will activate after a specified time interval. The time
    /// can be specified as day, hour, minute or any combination of them.
    /// - Parameters:
    ///   - day: The days of time interval.
    ///   - hour: The hours of time interval.
    ///   - minute: The days of time interval.
    ///   - mode: The alarm2 mode.
    public func setTimer2(
        day: UInt8 = 0, hour: UInt8 = 0, minute: UInt8 = 0, mode: Alarm2Mode
    ) {
        let current = readCurrent()
        if let current = current {
            let futureMinute = (current.minute + minute) % 60
            let futureHour = (current.hour + hour) % 24 +
                (current.minute + minute) / 60

            if current.year % 4 == 0 {
                daysInMonth[1] = 29
            }

            let totalDays = daysInMonth[Int(current.month - 1)]

            let futureDay = (current.day + day) % totalDays +
                (current.hour + hour) / 24


            setAlarm2(day: futureDay, hour: futureHour,
                      minute: futureMinute, mode: mode)
        }
    }

    /// Check if the specified alarm has been activated.
    /// If so, it returns true, if not, false.
    /// - Parameter alarm: The alarm 1 or 2.
    /// - Returns: A boolean value.
    public func alarmed(_ alarm: Int) -> Bool? {
        let data = readRegister(Register.status)
        var alarmFlag: UInt8 = 2

        if let data = data {
            alarmFlag = (data >> (alarm - 1)) & 0b1
        } else {
            print("read alarm status error")
            return nil
        }

        if alarmFlag == 1 {
            return true
        } else {
            return false
        }
    }

    /// Clear the alarm status.
    /// - Parameter alarm: The alarm 1 or 2.
    public func clearAlarm(_ alarm: Int) {
        let data = readRegister(Register.status)

        if let data = data {
            let value = data & (~(0b1 << (alarm - 1)))
            writeRegister(Register.status, value)
        } else {
            print("clear alarm error")
        }
    }

    /// The mode of alarm1.
    public enum Alarm1Mode: UInt8 {
        /// Alarm per second.
        case perSecond = 0x0F
        /// Alarm when seconds match.
        case second = 0x0E
        /// Alarm when minutes and seconds match.
        case minute = 0x0C
        /// Alarm when hours, minutes and seconds match.
        case hour = 0x08
        /// Alarm when day of month, hours, minutes and seconds match.
        case dayOfMonth = 0x00
        /// Alarm when day of week, hours, minutes and seconds match.
        /// It doesn't work when you set timer1 and timer2.
        case dayOfWeek = 0x10
    }

    /// The mode of alarm2.
    public enum Alarm2Mode: UInt8 {
        /// Alarm once per minute (00 seconds of every minute).
        case perMinute = 0x7
        /// Alarm when minutes match.
        case minute = 0x6
        /// Alarm when hours and minutes match.
        case hour = 0x4
        /// Alarm when day of month, hours, minutes and seconds match.
        case dayOfMonth = 0x0
        /// Alarm when day of week, hours, minutes and seconds match.
        /// It doesn't work when you set timer1 and timer2.
        case dayOfWeek = 0x8
    }


    /// Store the time info.
    public struct Time {
        public let year: UInt16
        public let month: UInt8
        public let day: UInt8
        public let hour: UInt8
        public let minute: UInt8
        public let second: UInt8
        public let dayOfWeek: UInt8

        public init(
            year: UInt16, month: UInt8, day: UInt8,
            hour: UInt8, minute: UInt8, second: UInt8,
            dayOfWeek: UInt8
        ) {
            self.year = year
            self.month = month
            self.day = day
            self.hour = hour
            self.minute = minute
            self.second = second
            self.dayOfWeek = dayOfWeek
        }
    }
}

extension DS3231 {
    private func lostPower() -> Bool? {
        let data = readRegister(Register.status)
        var stopFlag: UInt8 = 2

        if let data = data {
            stopFlag = data >> 7
        } else {
            print("read power status error")
            return nil
        }

        if stopFlag == 1 {
            return true
        } else {
            return false
        }
    }

    private func enable32K() {
        let data = readRegister(Register.status)

        if let data = data {
            writeRegister(Register.status, data | 0b1000)
        }
    }

    private func disable32K() {
        let data = readRegister(Register.status)

        if let data = data {
            writeRegister(Register.status, data & 0b0111)
        }
    }

    private func writeData(_ reg: Register, _ data: [UInt8]) {
        var data = data
        data.insert(reg.rawValue, at: 0)
        i2c.write(data, to: address)
    }


    private func writeRegister(_ reg: Register, _ value: UInt8) {
        i2c.write([reg.rawValue, value], to: address)
    }

    private func readRegister(_ reg: Register) -> UInt8? {
        i2c.write(reg.rawValue, to: address)
        let data = i2c.readByte(from: address)
        
        if let data = data {
            return data
        } else {
            print("readByte error")
            return nil
        }
    }

    private func bcdToBin(_ value: UInt8) -> UInt8 {
        return value - 6 * (value >> 4)
    }

    private func binToBcd(_ value: UInt8) -> UInt8 {
        return value + 6 * (value / 10)
    }

    private func setSqwMode(_ mode: SqwMode) {
        let data = readRegister(Register.control)
        if let data = data {
            var value = data & 0b0011
            value |= mode.rawValue
            writeRegister(Register.control, value)
        } else {
            print("set SqwMode error")
        }
    }

    private func disableAlarm(_ alarm: Int) {
        let data = readRegister(Register.control)

        if let data = data {
            let value = data & (~(0b1 << (alarm - 1)))
            writeRegister(Register.control, value)
        } else {
            print("disable alarm error")
        }
    }

    private enum Register: UInt8 {
        case second = 0x00
        case agingOffset = 0x10
        case alarm2 = 0x0B
        case alarm1 = 0x07
        case status = 0x0F
        case control = 0x0E
        case temperature = 0x11
    }

    private enum SqwMode: UInt8 {
      case off = 0x1C
      case hz1 = 0x00
      case kHz1 = 0x08
      case kHz4 = 0x10
      case kHz8 = 0x18
    }
}