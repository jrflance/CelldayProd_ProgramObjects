--liquibase formatted sql

--changeset Nicolas Griesdorn 9f924a6c stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2024-03-22
				:
	Description	: SP used in CRM to generate order commissions for MAs and reverse created commissions for account 2
				:
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_Generate_Manual_Order_Commissions]
    (
        @SessionID INT
        , @UserID INT
        , @Order_No INT
        , @Order_ID INT
        , @MA_AccountID INT
        , @CommissionAmount FLOAT
        , @Option INT --View,Update
    )
AS
BEGIN
    BEGIN TRY
    ----Error Handling (Global)---------------------------------------------------------------------------------------------------------------
        IF ISNULL(@SessionID, 0) <> 2
            RAISERROR ('This report is highly restricted. Please see your T-Cetra representative if you wish to request access.', 12, 1);

        IF @CommissionAmount < 0.00
            RAISERROR ('The Commission Amount entered cannot be less than 0, please enter a positive value and try again.', 12, 1);

        IF @UserID NOT IN (259617, 279685, 257210) --Restricted to Nic Griesdorn, Matt Moore, Tyler Fee
            RAISERROR ('This report is highly user restricted. Please have your manager escalate to IT Support if access is required.', 12, 1);
        ------View----------------------------------------------------------------------------------------------------------------------------------
        IF @Option = 0
            BEGIN
                SELECT * FROM dbo.Order_Commission
                WHERE
                    Orders_ID = @Order_ID
                    AND Account_ID IN (@MA_AccountID, 2)
                    AND Commission_Amt != 0.00
                    OR Order_No = @Order_No
                    AND Account_ID IN (@MA_AccountID, 2)
                    AND Commission_Amt != 0.00
            END;
        ------Update--------------------------------------------------------------------------------------------------------------------------------
        IF @Option = 1
            BEGIN

                DECLARE @Date DATE
                SET @Date = GETDATE()

                SET DATEFIRST 6

                DECLARE @UpcomingFriday DATETIME

                IF DATENAME(WEEKDAY, @Date) = 'Friday'
                    BEGIN
                        SET @UpcomingFriday = (SELECT DATEADD(DAY, 7, @Date))
                    END
                ELSE SET @UpcomingFriday = (SELECT DATEADD(D, 7 - DATEPART(DW, @Date), @Date))

                IF
                    EXISTS (
                        SELECT *
                        FROM dbo.Order_Commission
                        WHERE
                            Orders_ID = @Order_ID AND Account_ID = @MA_AccountID AND Commission_Amt > 0.00
                            OR Order_No = @Order_No AND Account_ID = @MA_AccountID AND Commission_Amt > 0.00
                    )
                    RAISERROR (
                        'The Order No provided already has a commission amount greater than 0 associated with it, please enter a different order number and try again.', -- noqa: LT05
                        12,
                        1
                    );

                IF EXISTS (SELECT * FROM dbo.Orders WHERE ID = @Order_ID AND Order_No <> @Order_No)
                    RAISERROR (
                        'The Order ID entered does not match the Order No provided, please enter the correct Order ID for this Order No and try again.', -- noqa: LT05
                        12,
                        1
                    );

                IF EXISTS (SELECT * FROM dbo.Order_Commission WHERE Orders_ID = @Order_ID AND Account_ID = 2 AND Commission_Amt <> @CommissionAmount)
                    RAISERROR (
                        'The commission amount entered does not match what is currently already given, please verify these 2 match and try again.',
                        12,
                        1
                    );

                IF EXISTS (SELECT * FROM dbo.Order_Commission WHERE Orders_ID = @Order_ID AND Account_ID = 2 AND Commission_Amt > 0.00)
                    BEGIN

                        IF EXISTS (SELECT * FROM dbo.Order_Commission WHERE Orders_ID = @Order_ID AND Account_ID = 2 AND Commission_Amt < 0.00)
                            RAISERROR (
                                'The Order_No entered already has a negative commission assoicated with it on Account 2, please escalate to IT Support if you think this in an error.', -- noqa: LT05
                                12,
                                1
                            );


                        INSERT INTO dbo.Order_Commission
                        (
                            Order_No,
                            Orders_ID,
                            Account_ID,
                            Commission_Amt,
                            Datedue,
                            InvoiceNum
                        )
                        VALUES
                        (
                            @Order_No,    -- Order_No - int
                            @Order_ID, -- Orders_ID - int
                            2, -- Account_ID - int
                            -1 * @CommissionAmount, -- Commission_Amt - decimal(7,2)
                            @UpcomingFriday, -- Datedue - datetime
                            NULL  -- InvoiceNum - int
                        )
                    END;


                INSERT INTO dbo.Order_Commission
                (
                    Order_No,
                    Orders_ID,
                    Account_ID,
                    Commission_Amt,
                    Datedue,
                    InvoiceNum
                )
                VALUES
                (
                    @Order_No,    -- Order_No - int
                    @Order_ID, -- Orders_ID - int
                    @MA_AccountID, -- Account_ID - int
                    @CommissionAmount, -- Commission_Amt - decimal(7, 2)
                    @UpcomingFriday, -- Datedue - datetime
                    NULL  -- InvoiceNum - int
                )

                SELECT * FROM dbo.Order_Commission
                WHERE Orders_ID = @Order_ID AND Commission_Amt <> 0.00
            END;


    END TRY
    BEGIN CATCH
        SELECT ERROR_MESSAGE() AS ErrorMessage;
    END CATCH
END;
