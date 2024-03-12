--liquibase formatted sql

--changeset  BrandonStahl:d2c914ed-f0a9-416c-bb24-002dda430e12 stripComments:false runOnChange:true splitStatements:false

-- noqa: disable=all
-- =============================================
--      Author : Jacob Lowe
--             :
--     Created : 2017-08-25
--             :
-- Description : Creates Subsidy orders
--             :
--  JL20170829 : Fix Inverse issue with price
--  JL20180530 : Add support for creating promo on order missing device
--  JL20180702 : Add support for NewNumber/Port promo
--  JL20180717 : Allowed for Subsidy orders that are 0 and allow Celina to create with when merchant entered invalid ESN
--  JL20180717 : Allowed Celina to apply on Airtime
--  JL20180717 : Clean up datedue, fix cashback table selection
--  JL20180810 : Allowed Celina to override promo already exists
--  JL20180906 : update Promo port/non port list
--  LZ20180926 : INC123836
--  LZ20181031 : Allow Port/NonPort promo an PIN Orders
--  JL20181128 : update Promo port/non port list
--  JL20181207 : update Promo port/non port list
--  JL20181212 : Fix Dateordered on new promos
--  JL20190320 : Fix addon to limit on addonfamily
--  JL20190614 : update Promo port/non port list
--  JL20191009 : update Promo port/non port list
--  JL20191024 : update Promo port/non port list
--  JL20191125 : update Promo port/non port list
-- KMH20200701 : Updated Promo port/non port list
-- KMH20200827 : Added promo 149 to port list when activation is a port
-- KMH20201110 : Added promos 161,167,169,171,173,175,177,179,181,183,
--             : 185,187,189,191,193,195,197,199,201,203,205,207,209,211,213
-- KMH20201210 : Changed User ID from 43126 to 261548; Remove Celina to add Bella
-- KMH20210113 : Added non-port promos 214,215,216,217,218,219,220,221,222,224,226,
--             : 228,230,231,232,233 and port promos 223,225,227,229
-- NG20210601  : Added Port promo 223
-- NG20210621  : Added Port promo 227
-- NG20210702  : Added Port promo 247
-- NG20210820  : Total Rework of Promo Port/Non List to be Autonomous
-- NG20210826  : Cleansed error messages throughout the script with a rework of some logic throughout
-- NG20210901  : Corrected bug of not finding "Port" in name of Promo
-- NG20220323  : Removed UserID limitation on OrderType lines(152-153) as it handled above on lines(78-81)
-- NG20230407  : Complete Refactor of Report to add BYOP/Branded cases and secondary rebate amounts to report. Also started logging users manual promos that are issued in the Logs schema
-- NG20230619  : Bug Fix from <> to >=
-- NG20231019: Refactor of Port/Non-Port error handling to include new Internal logic that was implemented recently
-- =============================================
-- noqa: enable=all

ALTER PROCEDURE [Report].[P_Report_CreateBrandedPromoOrder]
    (
        @ActivationOrderNo INT
        , @SimEsn VARCHAR(MAX)
        , @PIN VARCHAR(50)
        , @Promo INT
        , @CheckVsAdd BIT  --CheckVsAdd: ESN on Order|0| ESN Not on Order|1|
        , @HasPromoOverride BIT  -- 0 not override, 1 override
        , @PromoOverrideAmount NVARCHAR(MAX)
        , @Option INT --Normal Process,BYOP Process,Double Promotion Process
        , @UserId INT
    )
AS
BEGIN
    BEGIN TRY

        SET NOCOUNT ON;
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        DECLARE
            @ActAccountId INT,
            @ActTopMA INT,
            @ActivationOrderType INT,
            @ordertype INT,
            @Assigned_Merchant_ID INT,
            @Spiff_Amount DECIMAL(5, 2),
            @MaSpiffAmount DECIMAL(5, 2),
            @NewPortPromo BIT,
            @ActivationPort BIT,
            @PurchaseProductID INT,
            @POnumber INT,
            @DateOrdered DATETIME;

        IF (ISNULL((SELECT Account_ID FROM dbo.Users WHERE User_ID = ISNULL(@UserId, -1)), 0) <> 2)
            BEGIN
                -- noqa: disable=all
                SELECT
                    'This report is highly restricted! Please see your T-Cetra representative if you need access.' AS [Error Message];
                RETURN;
                -- noqa: enable=all
            END;
        ------ Start of Options
        IF @Option = 0
            BEGIN

                SELECT
                    p.Carrier_ID,
                    p.Sim_ID,
                    p.Active_Status,
                    p.Status,
                    p.Product_ID,
                    p.order_no,
                    p.Activation_Type,
                    p.Assigned_Merchant_ID,
                    p.PONumber,
                    p.status2,
                    p.Kit_Number
                FROM dbo.Phone_Active_Kit AS p
                WHERE p.order_no = @ActivationOrderNo OR p.Sim_ID = @SimEsn

            END;
        ------- Normal Manual Promotion Process
        IF @Option = 1
            BEGIN

                IF
                    EXISTS
                    (
                        SELECT 1
                        FROM dbo.Order_No
                        WHERE
                            Order_No = @ActivationOrderNo
                            AND OrderType_ID IN (1, 9)
                    )
                    AND NOT EXISTS
                    (
                        SELECT 1
                        FROM dbo.Orders
                        WHERE
                            Order_No = @ActivationOrderNo
                            AND SKU = @PIN
                    )
                    BEGIN
                        SELECT 'Given PIN is not tied to this order number.' AS [Error Message];
                        RETURN;
                    END;

                IF
                    NOT EXISTS
                    (
                        SELECT 1
                        FROM dbo.Order_No
                        WHERE
                            Order_No = @ActivationOrderNo
                            AND OrderType_ID IN (1, 9)
                    )
                    AND LEN(ISNULL(@PIN, '')) > 0
                    BEGIN
                        SELECT 'PIN can only be tied to a purchase order' AS [Error Message];
                        RETURN;
                    END;

                IF
                    NOT EXISTS
                    (
                        SELECT 1
                        FROM Products.tblPromotion AS p
                        WHERE p.PromotionId = @Promo
                    )
                    BEGIN
                        SELECT 'Promotion is not found' AS [Error Message];
                        RETURN;
                    END;

                IF
                    EXISTS
                    (
                        SELECT DISTINCT
                            cbp.PromotionId
                        FROM Products.tblCashBackPromotions AS cbp
                        WHERE cbp.PromotionId = @Promo
                    )
                    BEGIN
                        SET @NewPortPromo = 1;
                    END;

                IF
                    NOT EXISTS
                    (
                        SELECT 1
                        FROM dbo.Order_No AS n
                        JOIN dbo.Orders AS o
                            ON o.Order_No = n.Order_No
                        JOIN dbo.Products AS p
                            ON p.Product_ID = o.Product_ID
                        WHERE
                            n.Order_No = @ActivationOrderNo
                            AND
                            (
                                n.OrderType_ID IN (22, 23)
                                AND p.Product_Type = 3
                                OR
                                (
                                    n.OrderType_ID IN (1, 9)                    -- NG20220323
                                )
                            )
                            AND n.Void = 0
                            AND n.Process = 1
                            AND n.Filled = 1
                    )
                    BEGIN
                        SELECT 'Invalid OrderNo, Not an Activation Order, Order not filled.' AS [Error Message];
                        RETURN;
                    END;

                IF
                    EXISTS
                    (
                        SELECT 1
                        FROM dbo.Order_No AS n
                        WHERE
                            n.AuthNumber = CAST(@ActivationOrderNo AS VARCHAR(MAX))
                            AND n.OrderType_ID IN (59, 60)
                            AND n.OrderTotal <> 0
                    )
                    BEGIN
                        IF
                            (@UserId NOT IN (261548, 257210) OR ISNULL(@HasPromoOverride, 0) = 0)
                            OR @HasPromoOverride = 1
                            BEGIN
                                -- noqa: disable=all
                                SELECT
                                    'An Existing Promo Order Has Been Found or the incorrect option was selected, please make sure to use the Secondary Promotion option if you are trying to issue more then 1 Promotion.' AS [Error Message];
                                RETURN;
                                -- noqa: enable=all
                            END;
                    END;


                IF
                    NOT EXISTS (
                        SELECT 1
                        FROM dbo.Phone_Active_Kit AS pak
                        WHERE
                            pak.Sim_ID = @SimEsn
                            AND pak.Status = 1
                    )
                    BEGIN
                        SELECT
                            -- noqa: disable=all
                            'The SIM/ESN enter was not found, Please ensure the SIM/ESN is correct and try again.' AS [Error Message];
                            -- noqa: enable=all
                        RETURN;
                    END;

                IF
                    NOT EXISTS (
                        SELECT 1
                        FROM dbo.Phone_Active_Kit AS pak
                        WHERE
                            pak.Sim_ID = @SimEsn
                            AND pak.Status = 1
                            AND pak.Activation_Type IN ('branded', 'Handset', 'TCBranded')
                    )
                    BEGIN
                        SELECT
                            -- noqa: disable=all
                            'This Handset is not currently marked as branded or handset, Please escalate to ITSupport.' AS [Error Message];
                            -- noqa: enable=all
                        RETURN;
                    END;

                DECLARE @ActIna INT;
                SELECT @ActIna = pak.Active_Status
                FROM dbo.Phone_Active_Kit AS pak
                WHERE
                    pak.Sim_ID = @SimEsn
                    AND pak.Status = 1

                IF (
                    SELECT COUNT(1)
                    FROM dbo.Phone_Active_Kit AS pak
                    WHERE
                        pak.Status = 1
                        AND pak.Sim_ID = @SimEsn
                        AND pak.Active_Status = CASE
                            WHEN ISNULL(@CheckVsAdd, 1) = 1 THEN 0
                            ELSE 1
                        END
                ) <> 1
                    BEGIN
                        --Note: you can change this to something more meaningful if you want.
                        SELECT
                        -- noqa: disable=all
                            'This Handset is currently not marked as active/inactive. If the ESN is NOT on the order, the active status is expected to be zero. If the ESN is ON the order, the active status is expected to be one.'
                        -- noqa: enable=all
                        RETURN;
                    END

                IF (
                    SELECT COUNT(1)
                    FROM dbo.Phone_Active_Kit AS pak
                    WHERE
                        pak.Sim_ID = @SimEsn
                        AND pak.Activation_Type IN ('byop', 'branded')
                        AND pak.Status = 1
                ) > 1

                    BEGIN
                        SELECT
                        -- noqa: disable=all
                            'Multiple SIM/ESN(s) found have been found, Please view the ESN/SIM and see if a branded record exists please use the BYOP option to correct this and try again.' AS [Error Message];
                        -- noqa: enable=all
                        RETURN;
                    END;

                IF (
                    SELECT COUNT(1)
                    FROM dbo.Phone_Active_Kit AS pak
                    WHERE
                        pak.Sim_ID = @SimEsn
                        AND pak.Status = 1
                        AND (
                            (
                                (
                                    ISNULL(pak.Spiff_Amount, 0) <> 0
                                    OR ISNULL(pak.MaSpiffAmount, 0) <> 0
                                )
                                AND ISNULL(@NewPortPromo, 0) = 0
                            )
                            OR ISNULL(@NewPortPromo, 0) = 1
                        )
                ) <> 1



                    BEGIN
                        SELECT
                        -- noqa: disable=all
                            'No Subsidy amount was currently found in the Cashback Promotion Table (or Spiff Amount is not zero). Please check that there are no BYOP records attached to this Activation order if you get this message' AS [Error Message];
                        -- noqa: enable=all
                        RETURN;
                    END;

                SELECT
                    @ActAccountId = n.Account_ID,
                    @ActivationOrderType = n.OrderType_ID,
                    @ActTopMA = ISNULL(dbo.fn_GetTopParentAccountID_NotTcetra_2(n.Account_ID), 2)
                FROM dbo.Order_No AS n
                WHERE n.Order_No = @ActivationOrderNo;

                IF (ISNULL(@NewPortPromo, 0) = 1)
                    BEGIN
                        IF
                            EXISTS
                            (
                                SELECT 1
                                FROM dbo.Orders AS o
                                JOIN dbo.Order_No AS n
                                    ON n.Order_No = o.Order_No
                                JOIN dbo.tblOrderItemAddons AS oia
                                    ON
                                        oia.OrderID = o.ID
                                        AND oia.AddonsID = 26
                                        AND oia.AddonsValue = 'on'
                                WHERE n.Order_No = @ActivationOrderNo
                            )
                            BEGIN
                                SET @ActivationPort = 1;
                            END;

                        IF (
                            ISNULL(@ActivationPort, 0) = 1
                            AND @Promo IN (
                                SELECT p.PromotionId FROM Products.tblPromotion AS p
                                JOIN tcsys.tblRule AS r ON r.RuleSet = p.RuleSet
                                WHERE
                                    p.Status = 1
                                    AND (r.VectorId = 21 AND r.Value NOT IN ('External', 'Internal')) --NG20231019
                                    AND @ActivationOrderType IN (22, 23)
                            )
                        )
                            BEGIN
                                SELECT 'Activation is a Port and the Promo selected is not.' AS [Error Message];
                                RETURN;
                            END;

                        IF (
                            ISNULL(@ActivationPort, 0) = 0
                            AND @Promo IN (
                                SELECT p.PromotionId FROM Products.tblPromotion AS p
                                JOIN tcsys.tblRule AS r ON r.RuleSet = p.RuleSet
                                WHERE
                                    p.Status = 1
                                    AND ((r.VectorId = 21 AND r.OperandId = 4 AND r.Value LIKE 'External'))
                                    --NG20231019
                                    OR (r.VectorId = 21 AND r.OperandId = 6 AND r.Value NOT IN ('External', 'Internal'))
                                    AND @ActivationOrderType IN (22, 23)
                            )
                        )
                            BEGIN
                                SELECT 'Activation is not a Port and Promo selected is.' AS [Error Message];
                                RETURN;
                            END;

                        SELECT
                            @PurchaseProductID = pak.Product_ID,
                            @Assigned_Merchant_ID = pak.Assigned_Merchant_ID,
                            @POnumber = pak.PONumber
                        FROM dbo.Phone_Active_Kit AS pak
                        WHERE
                            pak.Sim_ID = @SimEsn
                            AND pak.Status = 1
                            AND pak.Active_Status = CASE
                                WHEN ISNULL(@CheckVsAdd, 1) = 1
                                    THEN
                                        0
                                ELSE
                                    1
                            END
                            AND pak.Activation_Type IN ('branded', 'Handset', 'TCBranded');

                        SELECT @DateOrdered = DateOrdered
                        FROM dbo.Order_No
                        WHERE Order_No = @POnumber;
                        ; WITH CTE AS (
                            SELECT MAX(cbp.CreateDate) AS [maxDate]
                            FROM Products.tblCashBackPromotions AS cbp
                            WHERE
                                cbp.ProductId = @PurchaseProductID
                                AND cbp.PromotionId = @Promo
                                AND cbp.CreateDate < @DateOrdered
                        )
                        SELECT @Spiff_Amount = (cbp.Amount * (-1))
                        FROM Products.tblCashBackPromotions AS cbp
                        WHERE
                            cbp.ProductId = @PurchaseProductID
                            AND cbp.PromotionId = @Promo
                            AND cbp.Amount <> 0
                            AND cbp.CreateDate =
                            (
                                SELECT CTE.maxDate FROM CTE
                            );

                        IF (ISNULL(@Spiff_Amount, 0) = 0)
                            BEGIN
                                SELECT
                                -- noqa: disable=all
                                    'The Cashback Promotion table amount for this ProductID is either 0 or Null, Please reach out to the MP team if you receive this error to correct the Product.' AS [Error Message];
                                -- noqa: enable=all
                                RETURN;
                            END;

                    END;
                IF (ISNULL(@NewPortPromo, 0) = 0)
                    BEGIN

                        SELECT
                            @Assigned_Merchant_ID = pak.Assigned_Merchant_ID,
                            @MaSpiffAmount = pak.MaSpiffAmount,
                            @Spiff_Amount = (pak.Spiff_Amount * (-1))
                        FROM dbo.Phone_Active_Kit AS pak
                        WHERE
                            pak.Sim_ID = @SimEsn
                            AND pak.Status = 1
                            AND pak.Active_Status = CASE
                                WHEN ISNULL(@CheckVsAdd, 1) = 1
                                    THEN
                                        0
                                ELSE
                                    1
                            END
                            AND
                            (
                                ISNULL(pak.Spiff_Amount, 0) <> 0
                                OR ISNULL(pak.MaSpiffAmount, 0) <> 0
                            )
                            AND pak.Activation_Type IN ('branded', 'Handset', 'TCBranded');

                    END;


                IF (@Assigned_Merchant_ID <> @ActAccountId)
                    BEGIN
                        SELECT
                        -- noqa: disable=all
                            'This Sim/Esn is not assigned to the account who performed this activation.' AS [Error Message];
                        -- noqa: enable=all
                        RETURN;
                    END;

                IF (ISNULL(@CheckVsAdd, 0) = 1)
                    BEGIN
                        IF
                            EXISTS
                            (
                                SELECT 1
                                FROM dbo.Order_No AS n
                                JOIN dbo.Orders AS o
                                    ON o.Order_No = n.Order_No
                                JOIN dbo.tblOrderItemAddons AS oia
                                    ON
                                        oia.OrderID = o.ID
                                        AND oia.AddonsValue = @SimEsn
                                        AND EXISTS
                                        (
                                            SELECT 1
                                            FROM dbo.tblAddonFamily AS af
                                            WHERE
                                                af.AddonID = oia.AddonsID
                                                AND af.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
                                        )
                                WHERE
                                    n.OrderType_ID IN (22, 23)
                                    AND n.Void = 0
                                    AND n.Process = 1
                                    AND n.Filled = 1
                            )
                            BEGIN
                                SELECT 'There is already a SIM/ESN on an Order.' AS [Error Message];
                                RETURN;
                            END;

                        IF (
                            EXISTS
                            (
                                SELECT 1
                                FROM dbo.Order_No AS n
                                JOIN dbo.Orders AS o
                                    ON o.Order_No = n.Order_No
                                JOIN dbo.tblOrderItemAddons AS oia
                                    ON oia.OrderID = o.ID
                                JOIN dbo.tblAddonFamily AS af
                                    ON
                                        oia.AddonsID = af.AddonID
                                        AND af.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
                                WHERE n.Order_No = @ActivationOrderNo
                            )
                            AND @UserId <> 261548
                        )
                            BEGIN
                                SELECT 'Order Has Device.' AS [Error Message];
                                RETURN;
                            END;
                    END;
                ELSE
                    BEGIN
                        IF
                            NOT EXISTS
                            (
                                SELECT 1
                                FROM dbo.Order_No AS n
                                JOIN dbo.Orders AS o
                                    ON o.Order_No = n.Order_No
                                JOIN dbo.tblOrderItemAddons AS oia
                                    ON
                                        oia.OrderID = o.ID
                                        AND oia.AddonsValue = @SimEsn
                                WHERE n.Order_No = @ActivationOrderNo
                            )
                            BEGIN
                                SELECT 'This Order does not have a SIM/ESN on it.' AS [Error Message];
                                RETURN;
                            END;
                    END;

                SET
                    @ordertype =
                    (
                        SELECT
                            CASE
                                WHEN AccountType_ID = 11
                                    THEN
                                        60
                                ELSE
                                    59
                            END AS [Ordertype]
                        FROM dbo.Account
                        WHERE Account_ID = @ActAccountId
                    );

                BEGIN TRY
                    BEGIN TRANSACTION
                    DECLARE @getdate DATETIME = GETDATE();

                    DECLARE
                        @NewOrderID INT,
                        @NewOrderNumber INT;
                    EXEC OrderManagment.P_OrderManagment_Build_Full_Order
                        @AccountID = @ActAccountId,               -- int
                        @Datefrom = @getdate,                     -- datetime
                        @OrdertypeID = @ordertype,                -- int
                        @OrderRefNumber = @ActivationOrderNo,     -- int
                        @ProductID = 6084,                        -- int
                        @Amount = @Spiff_Amount,                  -- decimal(9, 2)
                        @DiscountAmount = 0,                      -- decimal(5, 2)
                        @NewOrderID = @NewOrderID OUTPUT,         -- int
                        @NewOrderNumber = @NewOrderNumber OUTPUT; -- int

                    UPDATE a
                    SET
                        a.AvailableTotalCreditLimit_Amt = a.AvailableTotalCreditLimit_Amt + @Spiff_Amount * -1,
                        a.AvailableDailyCreditLimit_Amt = a.AvailableDailyCreditLimit_Amt + @Spiff_Amount * -1

                    FROM dbo.Account AS a
                    WHERE
                        a.Account_ID = @ActAccountId
                        AND a.AccountType_ID <> 11;

                    UPDATE dbo.Orders
                    SET
                        Dropship_Qty = @Promo,
                        SKU = IIF(LEN(ISNULL(@PIN, '')) = 0, NULL, @PIN)
                    WHERE ID = @NewOrderID;

                    UPDATE dbo.Order_No
                    SET Comments = ISNULL(Comments, '') + ' Created by ' + CAST(@UserId AS VARCHAR(MAX))
                    WHERE Order_No = @NewOrderNumber;

                    INSERT INTO dbo.tblOrderItemAddons
                    (
                        OrderID,
                        AddonsID,
                        AddonsValue
                    )
                    VALUES
                    (
                        @NewOrderID, -- OrderID - int
                        17,          -- AddonsID - int
                        @SimEsn      -- AddonsValue - nvarchar(200)
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
                        @NewOrderNumber,                             -- Order_No - int
                        @NewOrderID,                                 -- Orders_ID - int
                        @ActTopMA,                                   -- Account_ID - int
                        ISNULL(@MaSpiffAmount, 0),                   -- Commission_Amt - decimal(7, 2)
                        dbo.fnCalculateDueDate(@ActTopMA, @getdate), -- Datedue - datetime
                        NULL                                         -- InvoiceNum - int
                    );

                    SELECT
                        n.Order_No,
                        o.Price,
                        n.AuthNumber AS [ActivationOrder],
                        n.Account_ID
                    FROM dbo.Orders AS o
                    JOIN dbo.Order_No AS n
                        ON n.Order_No = o.Order_No
                    WHERE n.Order_No = @NewOrderNumber;

                    IF (ISNULL(@CheckVsAdd, 0) = 1)
                        BEGIN
                            EXEC Report.P_Report_Branded_Handset_Adjustment_Order
                                @AccountID = @Assigned_Merchant_ID, -- int
                                @ESN = @SimEsn,                     -- nvarchar(100)
                                @sessionID = 2;                     -- int
                        END;

                    INSERT INTO Logs.tblOperationLog (
                        [EntityTypeID]
                        , [OperationTypeID]
                        , [EntityID]
                        , [updateUser]
                        , [UpdateDate]
                        , [Details]
                    )
                    SELECT
                        50021 AS EntityTypeId,
                        50021 AS OperationTypeID,
                        'ManualPromotionProcess' AS EntityID,
                        @UserID AS updateUser,
                        GETDATE() AS UpdateDate,
                        'User: '
                        + CAST(@UserID AS NVARCHAR(15))
                        + ' Created a Manual Promotion Order '
                        + CAST(@NewOrderNumber AS NVARCHAR(15))
                        + ' for the amount of:'
                        + CAST(@Spiff_Amount AS NVARCHAR(15))
                        + ' using Promo ID:'
                        + CAST(@Promo AS NVARCHAR(15))
                            AS Details
                    COMMIT;
                END TRY
                BEGIN CATCH
                    ROLLBACK;
                    THROW;
                END CATCH;
            END;
        -------------- BYOP Option
        IF @Option = 2
            BEGIN

                IF @UserId NOT IN (259617, 257210)
                    BEGIN
                        RAISERROR (
                            'The user is not allowed to use this function. Please reach out to MP Services for help.', 12, 1
                        )
                    END;

                -- Find Activation Account infomation
                SELECT
                    @ActAccountId = n.Account_ID,
                    @ActivationOrderType = n.OrderType_ID,
                    @ActTopMA = ISNULL(dbo.fn_GetTopParentAccountID_NotTcetra_2(n.Account_ID), 2)
                FROM dbo.Order_No AS n
                WHERE n.Order_No = @ActivationOrderNo;

                --Error Handling
                IF
                    NOT EXISTS (
                        SELECT Sim_ID
                        FROM dbo.Phone_Active_Kit
                        WHERE
                            Sim_ID = @SimEsn
                            AND Activation_Type = 'branded'
                            AND Assigned_Merchant_ID = @ActAccountId
                            AND Status = 1
                    )
                    BEGIN
                        RAISERROR (
                            'There is not a branded record assoicated with this order, please make sure that a branded record exists and try again.',
                            12,
                            1
                        )
                    END;

                IF (ISNULL((SELECT Account_ID FROM dbo.Users WHERE User_ID = ISNULL(@UserId, -1)), 0) <> 2)
                    BEGIN
                        RAISERROR (
                            'This report is highly restricted! Please see your T-Cetra representative if you need access.',
                            12,
                            1
                        )
                    END;

                IF NOT EXISTS (SELECT 1 FROM Products.tblPromotion AS p WHERE p.PromotionId = @Promo)
                    BEGIN
                        RAISERROR (
                            'The Promotion entered has not been found, please verify the correct Promotion has been entered and try again.',
                            12,
                            1
                        )
                    END;


                DROP TABLE IF EXISTS #temp2

                SELECT
                    Sim_ID,
                    Pin_Number,
                    Area_Code,
                    Active_Status,
                    order_no
                INTO #temp2
                FROM dbo.Phone_Active_Kit
                WHERE order_no = @ActivationOrderNo

                BEGIN TRY
                    BEGIN TRANSACTION
                    UPDATE P
                    SET
                        Pin_Number = t1.Pin_Number
                        , Area_Code = t1.Area_Code
                        , Active_Status = 1
                        , order_no = t1.order_no
                        , Date_Updated = GETDATE()
                        , User_Updated = 'ManualPromoProcess'
                    FROM dbo.Phone_Active_Kit AS P
                    JOIN #temp2 AS t1 ON t1.Sim_ID = P.Sim_ID
                    WHERE t1.Sim_ID = P.Sim_ID AND P.Activation_Type <> 'byop' AND Assigned_Merchant_ID = @ActAccountId


                    UPDATE P
                    SET
                        Status = 0
                        , Date_Updated = GETDATE()
                        , User_Updated = 'ManualPromoProcess'
                    FROM dbo.Phone_Active_Kit AS P
                    JOIN #temp2 AS t1 ON t1.Sim_ID = P.Sim_ID
                    WHERE t1.Sim_ID = P.Sim_ID AND P.Activation_Type = 'byop' AND Assigned_Merchant_ID = @ActAccountId

                    DROP TABLE IF EXISTS #temp2


                    -- Finds PIN based Orders
                    IF
                        EXISTS
                        (
                            SELECT 1
                            FROM dbo.Order_No
                            WHERE
                                Order_No = @ActivationOrderNo
                                AND OrderType_ID IN (1, 9)
                        )
                        AND NOT EXISTS
                        (
                            SELECT 1
                            FROM dbo.Orders
                            WHERE
                                Order_No = @ActivationOrderNo
                                AND SKU = @PIN
                        )
                        BEGIN
                            SELECT 'Given PIN is not tied to this order number.' AS [Error Message];
                            RETURN;
                        END;

                    IF
                        NOT EXISTS
                        (
                            SELECT 1
                            FROM dbo.Order_No
                            WHERE
                                Order_No = @ActivationOrderNo
                                AND OrderType_ID IN (1, 9)
                        )
                        AND LEN(ISNULL(@PIN, '')) > 0
                        BEGIN
                            SELECT 'PIN can only be tied to a purchase order' AS [Error Message];
                            RETURN;
                        END;


                    IF
                        EXISTS
                        (
                            SELECT DISTINCT
                                cbp.PromotionId
                            FROM Products.tblCashBackPromotions AS cbp
                            WHERE cbp.PromotionId = @Promo
                        )
                        BEGIN
                            SET @NewPortPromo = 1;
                        END;

                    IF
                        NOT EXISTS
                        (
                            SELECT 1
                            FROM dbo.Order_No AS n
                            JOIN dbo.Orders AS o
                                ON o.Order_No = n.Order_No
                            JOIN dbo.Products AS p
                                ON p.Product_ID = o.Product_ID
                            WHERE
                                n.Order_No = @ActivationOrderNo
                                AND
                                (
                                    n.OrderType_ID IN (22, 23)
                                    AND p.Product_Type = 3
                                    OR
                                    (
                                        n.OrderType_ID IN (1, 9)                    -- NG20220323
                                    )
                                )
                                AND n.Void = 0
                                AND n.Process = 1
                                AND n.Filled = 1
                        )
                        BEGIN
                            SELECT 'Invalid OrderNo, Not an Activation Order, Order not filled.' AS [Error Message];
                            RETURN;
                        END;

                    IF
                        EXISTS
                        (
                            SELECT 1
                            FROM dbo.Order_No AS n
                            WHERE
                                n.AuthNumber = CAST(@ActivationOrderNo AS VARCHAR(MAX))
                                AND n.OrderType_ID IN (59, 60)
                                AND n.OrderTotal <> 0
                        )
                        BEGIN
                            IF ISNULL(@HasPromoOverride, 0) = 0 OR @HasPromoOverride = 1
                                BEGIN
                                    SELECT
                                    -- noqa: disable=all
                                        'An Existing Promo Order Has Been Found or the incorrect option was selected, please make sure to use the Promo Override option if you are trying to issue more then 1 Promotion.' AS [Error Message];
                                    -- noqa: enable=all
                                    RETURN;
                                END;
                        END;


                    IF
                        NOT EXISTS (
                            SELECT 1
                            FROM dbo.Phone_Active_Kit AS pak
                            WHERE
                                pak.Sim_ID = @SimEsn
                                AND pak.Status = 1
                        )
                        BEGIN
                            SELECT
                                'The SIM/ESN enter was not found, Please ensure the SIM/ESN is correct and try again.' AS [Error Message];
                            RETURN;
                        END;

                    IF
                        NOT EXISTS (
                            SELECT 1
                            FROM dbo.Phone_Active_Kit AS pak
                            WHERE
                                pak.Sim_ID = @SimEsn
                                AND pak.Status = 1
                                AND pak.Activation_Type IN ('branded', 'Handset', 'TCBranded')
                        )
                        BEGIN
                            SELECT
                                'This Handset is not currently marked as branded or handset, Please escalate to ITSupport.' AS [Error Message];
                            RETURN;
                        END;

                    DECLARE @ActIna1 INT;
                    SELECT @ActIna1 = pak.Active_Status
                    FROM dbo.Phone_Active_Kit AS pak
                    WHERE
                        pak.Sim_ID = @SimEsn
                        AND pak.Status = 1

                    IF (
                        SELECT COUNT(1)
                        FROM dbo.Phone_Active_Kit AS pak
                        WHERE
                            pak.Status = 1
                            AND pak.Sim_ID = @SimEsn
                            AND pak.Active_Status = CASE
                                WHEN ISNULL(@CheckVsAdd, 1) = 1 THEN 0
                                ELSE 1
                            END
                    ) <> 1
                        BEGIN
                            --Note: you can change this to something more meaningful if you want.
                            SELECT
                            -- noqa: disable=all
                                'This Handset is currently not marked as active/inactive. If the ESN is NOT on the order, the active status is expected to be zero. If the ESN is ON the order, the active status is expected to be one.'
                            -- noqa: enable=all
                            RETURN;
                        END

                    IF (
                        SELECT COUNT(1)
                        FROM dbo.Phone_Active_Kit AS pak
                        WHERE
                            pak.Sim_ID = @SimEsn
                            AND pak.Status = 1
                            AND (
                                (
                                    (
                                        ISNULL(pak.Spiff_Amount, 0) <> 0
                                        OR ISNULL(pak.MaSpiffAmount, 0) <> 0
                                    )
                                    AND ISNULL(@NewPortPromo, 0) = 0
                                )
                                OR ISNULL(@NewPortPromo, 0) = 1
                            )
                    ) <> 1
                        BEGIN
                            SELECT
                            -- noqa: disable=all
                                'No Subsidy amount was currently found in the Cashback Promotion Table (or Spiff Amount is not zero).' AS [Error Message];
                            -- noqa: enable=all
                            RETURN;
                        END;

                    IF (ISNULL(@NewPortPromo, 0) = 1)
                        BEGIN
                            IF
                                EXISTS
                                (
                                    SELECT 1
                                    FROM dbo.Orders AS o
                                    JOIN dbo.Order_No AS n
                                        ON n.Order_No = o.Order_No
                                    JOIN dbo.tblOrderItemAddons AS oia
                                        ON
                                            oia.OrderID = o.ID
                                            AND oia.AddonsID = 26
                                            AND oia.AddonsValue = 'on'
                                    WHERE n.Order_No = @ActivationOrderNo
                                )
                                BEGIN
                                    SET @ActivationPort = 1;
                                END;

                            IF (
                                ISNULL(@ActivationPort, 0) = 1
                                AND @Promo IN (
                                    SELECT p.PromotionId FROM Products.tblPromotion AS p
                                    JOIN tcsys.tblRule AS r ON r.RuleSet = p.RuleSet
                                    WHERE
                                        p.Status = 1
                                        AND (r.VectorId = 21 AND r.Value NOT IN ('External', 'Internal')) --NG20231019
                                        AND @ActivationOrderType IN (22, 23)
                                )
                            )
                                BEGIN
                                    SELECT 'Activation is a Port and the Promo selected is not.' AS [Error Message];
                                    RETURN;
                                END;

                            IF (
                                ISNULL(@ActivationPort, 0) = 0
                                AND @Promo IN (
                                    SELECT p.PromotionId FROM Products.tblPromotion AS p
                                    JOIN tcsys.tblRule AS r ON r.RuleSet = p.RuleSet
                                    WHERE
                                        p.Status = 1
                                        AND ((r.VectorId = 21 AND r.OperandId = 4 AND r.Value = 'External'))
                                        --NG20231019
                                        OR (r.VectorId = 21 AND r.OperandId = 6 AND r.Value NOT IN ('External', 'Internal'))
                                        AND @ActivationOrderType IN (22, 23)
                                )
                            )
                                BEGIN
                                    SELECT 'Activation is not a Port and Promo selected is.' AS [Error Message];
                                    RETURN;
                                END;

                            SELECT
                                @PurchaseProductID = pak.Product_ID,
                                @Assigned_Merchant_ID = pak.Assigned_Merchant_ID,
                                @POnumber = pak.PONumber
                            FROM dbo.Phone_Active_Kit AS pak
                            WHERE
                                pak.Sim_ID = @SimEsn
                                AND pak.Status = 1
                                AND pak.Active_Status = CASE
                                    WHEN ISNULL(@CheckVsAdd, 1) = 1
                                        THEN
                                            0
                                    ELSE
                                        1
                                END
                                AND pak.Activation_Type IN ('branded', 'Handset', 'TCBranded');

                            SELECT @DateOrdered = DateOrdered
                            FROM dbo.Order_No
                            WHERE Order_No = @POnumber;
                            ; WITH CTE AS (
                                SELECT MAX(cbp.CreateDate) AS [maxDate]
                                FROM Products.tblCashBackPromotions AS cbp
                                WHERE
                                    cbp.ProductId = @PurchaseProductID
                                    AND cbp.PromotionId = @Promo
                                    AND cbp.CreateDate < @DateOrdered
                            )
                            SELECT @Spiff_Amount = (cbp.Amount * (-1))
                            FROM Products.tblCashBackPromotions AS cbp
                            WHERE
                                cbp.ProductId = @PurchaseProductID
                                AND cbp.PromotionId = @Promo
                                AND cbp.Amount <> 0
                                AND cbp.CreateDate =
                                (
                                    SELECT CTE.maxDate FROM CTE
                                );

                            IF (ISNULL(@Spiff_Amount, 0) = 0)
                                BEGIN
                                    SELECT
                                    -- noqa: disable=all
                                        'The Cashback Promotion table amount for this ProductID is either 0 or Null, Please reach out to the MP team if you receive this error to correct the Product.' AS [Error Message]
                                    -- noqa: enable=all
                                    RETURN;
                                END;

                        END;

                    IF (ISNULL(@NewPortPromo, 0) = 0)
                        BEGIN

                            SELECT
                                @Assigned_Merchant_ID = pak.Assigned_Merchant_ID,
                                @MaSpiffAmount = pak.MaSpiffAmount,
                                @Spiff_Amount = (pak.Spiff_Amount * (-1))
                            FROM dbo.Phone_Active_Kit AS pak
                            WHERE
                                pak.Sim_ID = @SimEsn
                                AND pak.Status = 1
                                AND pak.Active_Status = CASE
                                    WHEN ISNULL(@CheckVsAdd, 1) = 1
                                        THEN
                                            0
                                    ELSE
                                        1
                                END
                                AND
                                (
                                    ISNULL(pak.Spiff_Amount, 0) <> 0
                                    OR ISNULL(pak.MaSpiffAmount, 0) <> 0
                                )
                                AND pak.Activation_Type IN ('branded', 'Handset', 'TCBranded');

                        END;


                    IF (@Assigned_Merchant_ID <> @ActAccountId)
                        BEGIN
                            SELECT
                                'This Sim/Esn is not assigned to the account who performed this activation.' AS [Error Message];
                            RETURN;
                        END;

                    IF (ISNULL(@CheckVsAdd, 0) = 1)
                        BEGIN
                            IF
                                EXISTS
                                (
                                    SELECT 1
                                    FROM dbo.Order_No AS n
                                    JOIN dbo.Orders AS o
                                        ON o.Order_No = n.Order_No
                                    JOIN dbo.tblOrderItemAddons AS oia
                                        ON
                                            oia.OrderID = o.ID
                                            AND oia.AddonsValue = @SimEsn
                                            AND EXISTS
                                            (
                                                SELECT 1
                                                FROM dbo.tblAddonFamily AS af
                                                WHERE
                                                    af.AddonID = oia.AddonsID
                                                    AND af.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
                                            )
                                    WHERE
                                        n.OrderType_ID IN (22, 23)
                                        AND n.Void = 0
                                        AND n.Process = 1
                                        AND n.Filled = 1
                                )
                                BEGIN
                                    SELECT 'There is already a SIM/ESN on an Order.' AS [Error Message];
                                    RETURN;
                                END;

                            IF (
                                EXISTS
                                (
                                    SELECT 1
                                    FROM dbo.Order_No AS n
                                    JOIN dbo.Orders AS o
                                        ON o.Order_No = n.Order_No
                                    JOIN dbo.tblOrderItemAddons AS oia
                                        ON oia.OrderID = o.ID
                                    JOIN dbo.tblAddonFamily AS af
                                        ON
                                            oia.AddonsID = af.AddonID
                                            AND af.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
                                    WHERE n.Order_No = @ActivationOrderNo
                                )
                                AND @UserId <> 261548
                            )
                                BEGIN
                                    SELECT 'Order Has Device.' AS [Error Message];
                                    RETURN;
                                END;
                        END;
                    ELSE
                        BEGIN
                            IF
                                NOT EXISTS
                                (
                                    SELECT 1
                                    FROM dbo.Order_No AS n
                                    JOIN dbo.Orders AS o
                                        ON o.Order_No = n.Order_No
                                    JOIN dbo.tblOrderItemAddons AS oia
                                        ON
                                            oia.OrderID = o.ID
                                            AND oia.AddonsValue = @SimEsn
                                    WHERE n.Order_No = @ActivationOrderNo
                                )
                                BEGIN
                                    SELECT 'This Order does not have a SIM/ESN on it.' AS [Error Message];
                                    RETURN;
                                END;
                        END;

                    SET
                        @ordertype =
                        (
                            SELECT
                                CASE
                                    WHEN AccountType_ID = 11
                                        THEN
                                            60
                                    ELSE
                                        59
                                END AS [Ordertype]
                            FROM dbo.Account
                            WHERE Account_ID = @ActAccountId
                        );

                    DECLARE @getdate1 DATETIME = GETDATE();

                    DECLARE
                        @NewOrderID1 INT,
                        @NewOrderNumber1 INT;
                    EXEC OrderManagment.P_OrderManagment_Build_Full_Order
                        @AccountID = @ActAccountId,               -- int
                        @Datefrom = @getdate1,                     -- datetime
                        @OrdertypeID = @ordertype,                -- int
                        @OrderRefNumber = @ActivationOrderNo,     -- int
                        @ProductID = 6084,                        -- int
                        @Amount = @Spiff_Amount,                  -- decimal(9, 2)
                        @DiscountAmount = 0,                      -- decimal(5, 2)
                        @NewOrderID = @NewOrderID1 OUTPUT,         -- int
                        @NewOrderNumber = @NewOrderNumber1 OUTPUT; -- int

                    UPDATE dbo.Orders
                    SET
                        Dropship_Qty = @Promo,
                        SKU = IIF(LEN(ISNULL(@PIN, '')) = 0, NULL, @PIN)
                    WHERE ID = @NewOrderID1;

                    UPDATE dbo.Order_No
                    SET Comments = ISNULL(Comments, '') + ' Created by ' + CAST(@UserId AS VARCHAR(MAX))
                    WHERE Order_No = @NewOrderNumber1;

                    UPDATE a
                    SET
                        a.AvailableTotalCreditLimit_Amt = a.AvailableTotalCreditLimit_Amt + @Spiff_Amount * -1,
                        a.AvailableDailyCreditLimit_Amt = a.AvailableDailyCreditLimit_Amt + @Spiff_Amount * -1
                    FROM dbo.Account AS a
                    WHERE
                        a.Account_ID = @ActAccountId
                        AND a.AccountType_ID <> 11;

                    INSERT INTO dbo.tblOrderItemAddons
                    (
                        OrderID,
                        AddonsID,
                        AddonsValue
                    )
                    VALUES
                    (
                        @NewOrderID1, -- OrderID - int
                        17,          -- AddonsID - int
                        @SimEsn      -- AddonsValue - nvarchar(200)
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
                        @NewOrderNumber1,                             -- Order_No - int
                        @NewOrderID1,                                 -- Orders_ID - int
                        @ActTopMA,                                   -- Account_ID - int
                        ISNULL(@MaSpiffAmount, 0),                   -- Commission_Amt - decimal(7, 2)
                        dbo.fnCalculateDueDate(@ActTopMA, @getdate1), -- Datedue - datetime
                        NULL                                         -- InvoiceNum - int
                    );

                    SELECT
                        n.Order_No,
                        o.Price,
                        n.AuthNumber AS [ActivationOrder],
                        n.Account_ID
                    FROM dbo.Orders AS o
                    JOIN dbo.Order_No AS n
                        ON n.Order_No = o.Order_No
                    WHERE n.Order_No = @NewOrderNumber1;

                    IF (ISNULL(@CheckVsAdd, 0) = 1)
                        BEGIN
                            EXEC Report.P_Report_Branded_Handset_Adjustment_Order
                                @AccountID = @Assigned_Merchant_ID, -- int
                                @ESN = @SimEsn,                     -- nvarchar(100)
                                @sessionID = 2;                     -- int
                        END;
                    -- Logging Begins
                    INSERT INTO Logs.tblOperationLog (
                        [EntityTypeID]
                        , [OperationTypeID]
                        , [EntityID]
                        , [updateUser]
                        , [UpdateDate]
                        , [Details]
                    )
                    SELECT
                        50021 AS EntityTypeId,
                        50021 AS OperationTypeID,
                        'ManualPromotionProcess' AS EntityID,
                        @UserID AS updateUser,
                        GETDATE() AS UpdateDate,
                        'User: '
                        + CAST(@UserID AS NVARCHAR(15))
                        + ' Created a Manual Promotion Order '
                        + CAST(@NewOrderNumber1 AS NVARCHAR(15))
                        + ' for the amount of: '
                        + CAST(@Spiff_Amount AS NVARCHAR(15))
                        + ' using Promo ID:'
                        + CAST(@Promo AS NVARCHAR(15))
                        + ' for a BYOP Branded activation record'
                            AS Details
                    COMMIT
                END TRY
                BEGIN CATCH
                    ROLLBACK;
                    THROW;
                END CATCH

            END;
        ----------- Duplicate Promo Option
        IF @Option = 3
            BEGIN

                IF @UserId NOT IN (259617, 257210)
                    BEGIN
                        RAISERROR (
                            'The user is not allowed to use this function. Please reach out to MP Services for help.', 12, 1
                        )
                    END;

                IF (
                    SELECT COUNT(1)
                    FROM dbo.Order_No
                    WHERE
                        AuthNumber = @ActivationOrderNo
                        AND OrderType_ID IN (59, 60)
                        AND Process = 1
                        AND Filled = 1
                        AND Void = 0
                ) >= 2 --NG20230619
                    BEGIN
                        SELECT
                        -- noqa: disable=all
                            'There are currently 2 non-void Promo orders already for this activation, please verify that this is correct and try again once an order has been voided.'
                        -- noqa: enable=all
                        RETURN;
                    END

                IF ISNULL(@HasPromoOverride, 0) = 0 AND ISNULL(@PromoOverrideAmount, '') = ''
                    BEGIN
                        SELECT
                            'There is currently no amount entered, please enter an amount in the Promo Override Amount column and try again.'
                        RETURN;
                    END

                IF @HasPromoOverride = 0 AND @PromoOverrideAmount IS NOT NULL
                    BEGIN
                        SELECT
                        -- noqa: disable=all
                            'There is currently an amount entered however the Promo Override has not been enabled, please enable the Promo Override option and try again.'
                        -- noqa: enable=all
                        RETURN;
                    END

                IF
                    EXISTS
                    (
                        SELECT 1
                        FROM dbo.Order_No
                        WHERE
                            Order_No = @ActivationOrderNo
                            AND OrderType_ID IN (1, 9)
                    )
                    AND NOT EXISTS
                    (
                        SELECT 1
                        FROM dbo.Orders
                        WHERE
                            Order_No = @ActivationOrderNo
                            AND SKU = @PIN
                    )
                    BEGIN
                        SELECT 'Given PIN is not tied to this order number.' AS [Error Message];
                        RETURN;
                    END;

                IF
                    NOT EXISTS
                    (
                        SELECT 1
                        FROM dbo.Order_No
                        WHERE
                            Order_No = @ActivationOrderNo
                            AND OrderType_ID IN (1, 9)
                    )
                    AND LEN(ISNULL(@PIN, '')) > 0
                    BEGIN
                        SELECT 'PIN can only be tied to a purchase order' AS [Error Message];
                        RETURN;
                    END;

                IF
                    NOT EXISTS
                    (
                        SELECT 1
                        FROM Products.tblPromotion AS p
                        WHERE p.PromotionId = @Promo
                    )
                    BEGIN
                        SELECT 'Promotion is not found' AS [Error Message];
                        RETURN;
                    END;

                IF
                    EXISTS
                    (
                        SELECT DISTINCT
                            cbp.PromotionId
                        FROM Products.tblCashBackPromotions AS cbp
                        WHERE cbp.PromotionId = @Promo
                    )
                    BEGIN
                        SET @NewPortPromo = 1;
                    END;

                IF
                    NOT EXISTS
                    (
                        SELECT 1
                        FROM dbo.Order_No AS n
                        JOIN dbo.Orders AS o
                            ON o.Order_No = n.Order_No
                        JOIN dbo.Products AS p
                            ON p.Product_ID = o.Product_ID
                        WHERE
                            n.Order_No = @ActivationOrderNo
                            AND
                            (
                                n.OrderType_ID IN (22, 23)
                                AND p.Product_Type = 3
                                OR
                                (
                                    n.OrderType_ID IN (1, 9)                    -- NG20220323
                                )
                            )
                            AND n.Void = 0
                            AND n.Process = 1
                            AND n.Filled = 1
                    )
                    BEGIN
                        SELECT 'Invalid OrderNo, Not an Activation Order, Order not filled.' AS [Error Message];
                        RETURN;
                    END;


                IF
                    NOT EXISTS (
                        SELECT 1
                        FROM dbo.Phone_Active_Kit AS pak
                        WHERE
                            pak.Sim_ID = @SimEsn
                            AND pak.Status = 1
                    )
                    BEGIN
                        SELECT
                            'The SIM/ESN enter was not found, Please ensure the SIM/ESN is correct and try again.' AS [Error Message];
                        RETURN;
                    END;

                IF
                    NOT EXISTS (
                        SELECT 1
                        FROM dbo.Phone_Active_Kit AS pak
                        WHERE
                            pak.Sim_ID = @SimEsn
                            AND pak.Status = 1
                            AND pak.Activation_Type IN ('branded', 'Handset', 'TCBranded')
                    )
                    BEGIN
                        SELECT
                            'This Handset is not currently marked as branded or handset, Please escalate to ITSupport.' AS [Error Message];
                        RETURN;
                    END;

                DECLARE @ActIna2 INT;
                SELECT @ActIna2 = pak.Active_Status
                FROM dbo.Phone_Active_Kit AS pak
                WHERE
                    pak.Sim_ID = @SimEsn
                    AND pak.Status = 1

                IF (
                    SELECT COUNT(1)
                    FROM dbo.Phone_Active_Kit AS pak
                    WHERE
                        pak.Status = 1
                        AND pak.Sim_ID = @SimEsn
                        AND pak.Active_Status = CASE
                            WHEN ISNULL(@CheckVsAdd, 1) = 1 THEN 0
                            ELSE 1
                        END
                ) <> 1
                    BEGIN
                        --Note: you can change this to something more meaningful if you want.
                        SELECT
                        -- noqa: disable=all
                            'This Handset is currently not marked as active/inactive. If the ESN is NOT on the order, the active status is expected to be zero. If the ESN is ON the order, the active status is expected to be one.'
                        -- noqa: enable=all
                        RETURN;
                    END

                SELECT
                    @ActAccountId = n.Account_ID,
                    @ActivationOrderType = n.OrderType_ID,
                    @ActTopMA = ISNULL(dbo.fn_GetTopParentAccountID_NotTcetra_2(n.Account_ID), 2)
                FROM dbo.Order_No AS n
                WHERE n.Order_No = @ActivationOrderNo;

                IF (ISNULL(@NewPortPromo, 0) = 1)
                    BEGIN
                        IF
                            EXISTS
                            (
                                SELECT 1
                                FROM dbo.Orders AS o
                                JOIN dbo.Order_No AS n
                                    ON n.Order_No = o.Order_No
                                JOIN dbo.tblOrderItemAddons AS oia
                                    ON
                                        oia.OrderID = o.ID
                                        AND oia.AddonsID = 26
                                        AND oia.AddonsValue = 'on'
                                WHERE n.Order_No = @ActivationOrderNo
                            )
                            BEGIN
                                SET @ActivationPort = 1;
                            END;

                        IF (
                            ISNULL(@ActivationPort, 0) = 1
                            AND @Promo IN (
                                SELECT p.PromotionId FROM Products.tblPromotion AS p
                                JOIN tcsys.tblRule AS r ON r.RuleSet = p.RuleSet
                                WHERE
                                    p.Status = 1
                                    AND (r.VectorId = 21 AND r.Value NOT IN ('External', 'Internal')) --NG20231019
                                    AND @ActivationOrderType IN (22, 23)
                            )
                        )
                            BEGIN
                                SELECT 'Activation is a Port and the Promo selected is not.' AS [Error Message];
                                RETURN;
                            END;

                        IF (
                            ISNULL(@ActivationPort, 0) = 0
                            AND @Promo IN (
                                SELECT p.PromotionId FROM Products.tblPromotion AS p
                                JOIN tcsys.tblRule AS r ON r.RuleSet = p.RuleSet
                                WHERE
                                    p.Status = 1
                                    AND ((r.VectorId = 21 AND r.OperandId = 4 AND r.Value = 'External'))
                                    --NG20231019
                                    OR (r.VectorId = 21 AND r.OperandId = 6 AND r.Value NOT IN ('External', 'Internal'))
                                    AND @ActivationOrderType IN (22, 23)
                            )
                        )
                            BEGIN
                                SELECT 'Activation is not a Port and Promo selected is.' AS [Error Message];
                                RETURN;
                            END;

                        SELECT
                            @PurchaseProductID = pak.Product_ID,
                            @Assigned_Merchant_ID = pak.Assigned_Merchant_ID,
                            @POnumber = pak.PONumber
                        FROM dbo.Phone_Active_Kit AS pak
                        WHERE
                            pak.Sim_ID = @SimEsn
                            AND pak.Status = 1
                            AND pak.Active_Status = CASE
                                WHEN ISNULL(@CheckVsAdd, 1) = 1
                                    THEN
                                        0
                                ELSE
                                    1
                            END
                            AND pak.Activation_Type IN ('branded', 'Handset', 'TCBranded');

                        SELECT @DateOrdered = DateOrdered
                        FROM dbo.Order_No
                        WHERE Order_No = @POnumber;
                        ; WITH CTE AS (
                            SELECT MAX(cbp.CreateDate) AS [maxDate]
                            FROM Products.tblCashBackPromotions AS cbp
                            WHERE
                                cbp.ProductId = @PurchaseProductID
                                AND cbp.PromotionId = @Promo
                                AND cbp.CreateDate < @DateOrdered
                        )
                        SELECT @Spiff_Amount = @PromoOverrideAmount
                        FROM Products.tblCashBackPromotions AS cbp
                        WHERE
                            cbp.ProductId = @PurchaseProductID
                            AND cbp.PromotionId = @Promo
                            AND cbp.Amount <> 0
                            AND cbp.CreateDate =
                            (
                                SELECT CTE.maxDate FROM CTE
                            );

                    END;

                IF (ISNULL(@NewPortPromo, 0) = 0)
                    BEGIN

                        SELECT
                            @Assigned_Merchant_ID = pak.Assigned_Merchant_ID,
                            @MaSpiffAmount = pak.MaSpiffAmount,
                            @Spiff_Amount = (pak.Spiff_Amount * (-1))
                        FROM dbo.Phone_Active_Kit AS pak
                        WHERE
                            pak.Sim_ID = @SimEsn
                            AND pak.Status = 1
                            AND pak.Active_Status = CASE
                                WHEN ISNULL(@CheckVsAdd, 1) = 1
                                    THEN
                                        0
                                ELSE
                                    1
                            END
                            AND
                            (
                                ISNULL(pak.Spiff_Amount, 0) <> 0
                                OR ISNULL(pak.MaSpiffAmount, 0) <> 0
                            )
                            AND pak.Activation_Type IN ('branded', 'Handset', 'TCBranded');

                    END;


                IF (@Assigned_Merchant_ID <> @ActAccountId)
                    BEGIN
                        SELECT
                            'This Sim/Esn is not assigned to the account who performed this activation.' AS [Error Message];
                        RETURN;
                    END;

                IF (ISNULL(@CheckVsAdd, 0) = 1)
                    BEGIN
                        IF
                            EXISTS
                            (
                                SELECT 1
                                FROM dbo.Order_No AS n
                                JOIN dbo.Orders AS o
                                    ON o.Order_No = n.Order_No
                                JOIN dbo.tblOrderItemAddons AS oia
                                    ON
                                        oia.OrderID = o.ID
                                        AND oia.AddonsValue = @SimEsn
                                        AND EXISTS
                                        (
                                            SELECT 1
                                            FROM dbo.tblAddonFamily AS af
                                            WHERE
                                                af.AddonID = oia.AddonsID
                                                AND af.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
                                        )
                                WHERE
                                    n.OrderType_ID IN (22, 23)
                                    AND n.Void = 0
                                    AND n.Process = 1
                                    AND n.Filled = 1
                            )
                            BEGIN
                                SELECT 'There is already a SIM/ESN on an Order.' AS [Error Message];
                                RETURN;
                            END;

                        IF (
                            EXISTS
                            (
                                SELECT 1
                                FROM dbo.Order_No AS n
                                JOIN dbo.Orders AS o
                                    ON o.Order_No = n.Order_No
                                JOIN dbo.tblOrderItemAddons AS oia
                                    ON oia.OrderID = o.ID
                                JOIN dbo.tblAddonFamily AS af
                                    ON
                                        oia.AddonsID = af.AddonID
                                        AND af.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
                                WHERE n.Order_No = @ActivationOrderNo
                            )
                            AND @UserId <> 261548
                        )
                            BEGIN
                                SELECT 'Order Has Device.' AS [Error Message];
                                RETURN;
                            END;
                    END;
                ELSE
                    BEGIN
                        IF
                            NOT EXISTS
                            (
                                SELECT 1
                                FROM dbo.Order_No AS n
                                JOIN dbo.Orders AS o
                                    ON o.Order_No = n.Order_No
                                JOIN dbo.tblOrderItemAddons AS oia
                                    ON
                                        oia.OrderID = o.ID
                                        AND oia.AddonsValue = @SimEsn
                                WHERE n.Order_No = @ActivationOrderNo
                            )
                            BEGIN
                                SELECT 'This Order does not have a SIM/ESN on it.' AS [Error Message];
                                RETURN;
                            END;
                    END;


                SET
                    @ordertype =
                    (
                        SELECT
                            CASE
                                WHEN AccountType_ID = 11
                                    THEN
                                        60
                                ELSE
                                    59
                            END AS [Ordertype]
                        FROM dbo.Account
                        WHERE Account_ID = @ActAccountId
                    );

                BEGIN TRY
                    BEGIN TRANSACTION
                    DECLARE @getdate2 DATETIME = GETDATE();

                    DECLARE
                        @NewOrderID2 INT,
                        @NewOrderNumber2 INT,
                        @PromoOverrideAmount2 DECIMAL(9, 2) = (CAST(@PromoOverrideAmount AS DECIMAL(9, 2)) * (-1))
                    EXEC OrderManagment.P_OrderManagment_Build_Full_Order
                        @AccountID = @ActAccountId,               -- int
                        @Datefrom = @getdate2,                     -- datetime
                        @OrdertypeID = @ordertype,                -- int
                        @OrderRefNumber = @ActivationOrderNo,     -- int
                        @ProductID = 6084,                        -- int
                        @Amount = @PromoOverrideAmount2,                  -- decimal(9, 2)
                        @DiscountAmount = 0,                      -- decimal(5, 2)
                        @NewOrderID = @NewOrderID2 OUTPUT,         -- int
                        @NewOrderNumber = @NewOrderNumber2 OUTPUT; -- int

                    UPDATE dbo.Orders
                    SET
                        Dropship_Qty = @Promo,
                        SKU = IIF(LEN(ISNULL(@PIN, '')) = 0, NULL, @PIN)
                    WHERE ID = @NewOrderID2;

                    UPDATE dbo.Order_No
                    SET Comments = ISNULL(Comments, '') + ' Created by ' + CAST(@UserId AS VARCHAR(MAX))
                    WHERE Order_No = @NewOrderNumber2;

                    UPDATE a
                    SET
                        a.AvailableTotalCreditLimit_Amt = a.AvailableTotalCreditLimit_Amt + @Spiff_Amount * -1,
                        a.AvailableDailyCreditLimit_Amt = a.AvailableDailyCreditLimit_Amt + @Spiff_Amount * -1

                    FROM dbo.Account AS a
                    WHERE
                        a.Account_ID = @ActAccountId
                        AND a.AccountType_ID <> 11;

                    INSERT INTO dbo.tblOrderItemAddons
                    (
                        OrderID,
                        AddonsID,
                        AddonsValue
                    )
                    VALUES
                    (
                        @NewOrderID2, -- OrderID - int
                        17,          -- AddonsID - int
                        @SimEsn      -- AddonsValue - nvarchar(200)
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
                        @NewOrderNumber2,                             -- Order_No - int
                        @NewOrderID2,                                 -- Orders_ID - int
                        @ActTopMA,                                   -- Account_ID - int
                        ISNULL(@MaSpiffAmount, 0),                   -- Commission_Amt - decimal(7, 2)
                        dbo.fnCalculateDueDate(@ActTopMA, @getdate2), -- Datedue - datetime
                        NULL                                         -- InvoiceNum - int
                    );

                    SELECT
                        n.Order_No,
                        o.Price,
                        n.AuthNumber AS [ActivationOrder],
                        n.Account_ID
                    FROM dbo.Orders AS o
                    JOIN dbo.Order_No AS n
                        ON n.Order_No = o.Order_No
                    WHERE n.Order_No = @NewOrderNumber2;



                    IF (ISNULL(@CheckVsAdd, 0) = 1)
                        BEGIN
                            EXEC Report.P_Report_Branded_Handset_Adjustment_Order
                                @AccountID = @Assigned_Merchant_ID, -- int
                                @ESN = @SimEsn,                     -- nvarchar(100)
                                @sessionID = 2;                     -- int


                        END;

                    -- Logging Begins
                    INSERT INTO Logs.tblOperationLog (
                        [EntityTypeID]
                        , [OperationTypeID]
                        , [EntityID]
                        , [updateUser]
                        , [UpdateDate]
                        , [Details]
                    )
                    SELECT
                        50021 AS EntityTypeId,
                        50021 AS OperationTypeID,
                        'ManualPromotionProcess' AS EntityID,
                        @UserID AS updateUser,
                        GETDATE() AS UpdateDate,
                        'User: '
                        + CAST(@UserID AS NVARCHAR(15))
                        + ' Created a Secondary Manual Promotion Order '
                        + CAST(@NewOrderNumber2 AS NVARCHAR(15))
                        + ' for the amount of: -'
                        + CAST(@PromoOverrideAmount AS NVARCHAR(15))
                        + ' using Promo ID:'
                        + CAST(@Promo AS NVARCHAR(15))
                            AS Details
                    COMMIT
                END TRY
                BEGIN CATCH
                    ROLLBACK;
                    THROW;
                END CATCH
            END;
    END TRY
    BEGIN CATCH
        SELECT
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage
    END CATCH
END;
