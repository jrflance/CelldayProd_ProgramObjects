--liquibase formatted sql

--changeset Nicolas Griesdorn 93e17418 stripComments:false runOnChange:true splitStatements:false
-- =============================================
--      Author : Nic Griesdorn
--             :
--     Created : 2024-05-01
--             :
-- Description : Creates Subsidy orders
--             :
-- =============================================
CREATE OR ALTER PROCEDURE [Report].[P_Report_Create_FillBrandedPromoOrderOver1Year]
    (
        @ActivationOrderNo INT
        , @SimEsn VARCHAR(MAX)
        , @Promo INT
        , @PromoOrderNo INT
        , @Amount FLOAT
        , @Option INT --View,Normal Process
        , @UserId INT
    )
AS
BEGIN TRY
    IF @UserID NOT IN (259617, 279685, 257210) --Restricted to Nic Griesdorn, Matt Moore, Tyler Fee
        RAISERROR ('This report is highly user restricted. Please have your manager escalate to IT Support if access is required.', 12, 1);

    ----------------------------------------------------------------------------------------------------------------- Start of Options
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

    ----------------------------------------------------------------------------------------------------------------- Normal Manual Promotion Process
    IF @Option = 1
        BEGIN

            CREATE TABLE #temp
            (
                SIM VARCHAR(MAX),
                OrderNo INT,
                Promo INT,
                Amount DECIMAL(5, 2),
                PromoOrderNo INT
            );


            INSERT INTO #temp VALUES (@SimEsn, @ActivationOrderNo, @Promo, @Amount, NULL)

            IF ISNULL(@Amount, 0) = 0
                RAISERROR ('The Amount cannot be left empty, please ensure an amount is entered and try again.', 14, 1);

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
                                n.OrderType_ID IN (1, 9)
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
                    SELECT
                        'An Existing Promo Order Has Been Found, please make sure to use the Branded Promo Order report if you are trying to issue more then 1 Promotion.' AS [Error Message]; -- noqa: LT05
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
                    SELECT 'The SIM/ESN enter was not found, Please ensure the SIM/ESN is correct and try again.' AS [Error Message];
                    RETURN;
                END;


            IF EXISTS (SELECT t.* FROM #temp AS t LEFT JOIN Order_No ON t.OrderNo = Order_No.Order_No WHERE Order_No.Order_No IS NULL)
                BEGIN
                    SELECT
                        (
                            'One or more order(s) are not found in the DB, make sure to validate that all orders are in the correct format and try again.' -- noqa: LT05
                        )
                            AS [Error]
                    RETURN;
                END;

            IF
                EXISTS (
                    SELECT t.*
                    FROM #temp AS t
                    LEFT JOIN dbo.Phone_Active_Kit ON t.SIM = dbo.Phone_Active_Kit.Sim_ID
                    WHERE dbo.Phone_Active_Kit.Sim_ID IS NULL
                )
                BEGIN
                    SELECT
                        (
                            'One or more ESN/Sim(s) are not found in the DB, make sure to validate that all ESN/Sim(s) are in the correct format and try again.' -- noqa: LT05
                        ) AS [Error]
                    RETURN;
                END;




            DECLARE
                @ActAccountId INT,
                @ActTopMA INT,
                @ordertype INT,
                @Spiff_Amount FLOAT,
                @PIN VARCHAR(30)


            DECLARE Promos CURSOR FOR
            SELECT TOP 1000
                sim,
                ORDERno,
                promo,
                amount
            FROM #temp
            WHERE
                ORDERno NOT IN (
                    SELECT t.ORDERno FROM #temp AS t
                    JOIN dbo.Order_No AS o WITH (READUNCOMMITTED)
                        ON
                            o.AuthNumber = CAST(t.ORDERno AS NVARCHAR(20))
                            AND o.OrderType_ID IN (59, 60)
                            AND o.Filled = 1
                            AND o.Process = 1
                            AND o.Void = 0
                )




            OPEN Promos
            FETCH NEXT FROM Promos INTO @SimEsn, @ActivationOrderNo, @Promo, @Amount
            WHILE @@FETCH_STATUS = 0
                BEGIN

                    SET @Spiff_Amount = -1 * (@Amount)



                    SELECT
                        @ActAccountId = n.Account_ID,
                        @ActTopMA = ISNULL(dbo.fn_GetTopParentAccountID_NotTcetra_2(n.Account_ID), 2)
                    FROM dbo.Order_No AS n
                    WHERE n.Order_No = @ActivationOrderNo;

                    SELECT @PIN = SKU FROM dbo.Orders
                    WHERE
                        Order_No = @ActivationOrderNo
                        AND ParentItemID = 0

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

                    UPDATE dbo.Orders
                    SET
                        Dropship_Qty = @Promo,
                        SKU = IIF(LEN(ISNULL(@PIN, '')) = 0, NULL, @PIN)
                    WHERE ID = @NewOrderID;

                    UPDATE dbo.Order_No
                    SET Comments = ISNULL(Comments, '') + ' Created by ' + CAST('PromoFillCRM' AS VARCHAR(MAX))
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

                    UPDATE T
                    SET t.PromoOrderNO = @NewOrderNumber
                    FROM #temp AS t
                    WHERE t.ORDERno = @ActivationOrderNo

                    FETCH NEXT FROM Promos INTO @SimEsn, @ActivationOrderNo, @Promo, @Spiff_Amount
                END

            CLOSE Promos
            DEALLOCATE Promos

            INSERT INTO Logs.tblOperationLog (
                [EntityTypeID]
                , [OperationTypeID]
                , [EntityID]
                , [updateUser]
                , [UpdateDate]
                , [Details]
            )
            SELECT
                50022 AS EntityTypeId,
                50022 AS OperationTypeID,
                'Over1YearManualPromoProcess' AS EntityID,
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

            SELECT t.* FROM #temp AS t
        END;
    ----------------------------------------------------------------------------------------------------------------- Fill Promos
    IF @Option = 2
        BEGIN

            IF NOT EXISTS (SELECT * FROM dbo.Order_No WHERE Order_No = @PromoOrderNo AND OrderType_ID IN (59, 60))
                RAISERROR (
                    'The following order either does not exist or is not a Promo Order type, please ensure that the correct order is entered and try again.', -- noqa: LT05
                    14,
                    1
                );

            IF EXISTS (SELECT o.* FROM dbo.Order_No AS o WHERE o.Order_No = @PromoOrderNo AND o.OrderType_ID IN (59, 60) AND o.Paid = 1)
                RAISERROR ('The Promo order you are attempting to fill is already marked as paid.', 14, 1);

            UPDATE dbo.Order_No
            SET
                Process = 1
                , Filled = 1
                , Void = 0
                , DateFilled = GETDATE()
                , Admin_Updated = GETDATE()
                , Admin_Name = 'PromoFillCRM'
            WHERE Order_No = @PromoOrderNo

            SELECT o.Order_No, o.Process, o.Filled, o.Paid, o.Void, o.DateOrdered, o.DateFilled, o.DateDue, o.OrderTotal FROM dbo.Order_No AS o
            WHERE o.Order_No = @PromoOrderNo

            INSERT INTO Logs.tblOperationLog (
                [EntityTypeID]
                , [OperationTypeID]
                , [EntityID]
                , [updateUser]
                , [UpdateDate]
                , [Details]
            )
            SELECT
                50023 AS EntityTypeId,
                50023 AS OperationTypeID,
                'FillPromoProcess' AS EntityID,
                @UserID AS updateUser,
                GETDATE() AS UpdateDate,
                'User: ' + CAST(@UserID AS NVARCHAR(15)) + ' Filled a Promotion Order ' + CAST(@PromoOrderNo AS NVARCHAR(15)) + ' Manually'
                    AS Details
        END;
END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
