--liquibase formatted sql
--changeset MoeDaaboul:795f1910 stripComments:false runOnChange:true splitStatements:false
-- =============================================
-- Author:		zaher al sabbagh
-- Create date: 2015-10-26
-- Description:	get the first and second level for the delay spiff dashboard
-- =============================================
ALTER PROCEDURE [Report].[P_Report_GetInstantSpiffDashboardActivationDetails]
    -- Add the parameters for the stored procedure here
    @OrderNOList Report.TYPEORDERNO READONLY,
    @Account_ID INT
AS
BEGIN
    -- SET NOCOUNT ON added to prevent extra result sets from
    -- interfering with SELECT statements.
    SET NOCOUNT ON;

    -- Insert statements for procedure here

    SELECT
        o.OrderType_ID, CAST(o.DateFilled AS DATETIME) AS [Date_Ordered],
        o.Order_No AS [OrderNo],
        ISNULL(o.OrderTotal, 0) AS [Price],
        '' AS [Product],
        o.DateDue AS [Date_Due],
        o.Reason,
        u.UserName,
        o.AuthNumber
    FROM dbo.Order_No AS o WITH (READUNCOMMITTED)
    JOIN @OrderNOList AS onl ON CAST(onl.orderNo AS NVARCHAR(50)) = o.AuthNumber
    JOIN users AS u ON o.User_ID = u.User_ID
    WHERE
        o.OrderType_ID IN (45, 46, 31, 32)
        AND o.Filled = 1
        AND o.Process = 1
        AND o.Void = 0
        AND o.Account_ID = @Account_ID
    UNION ALL
    SELECT
        o.OrderType_ID, CAST(o.DateFilled AS DATETIME) AS [Date_Ordered],
        o.Order_No AS [OrderNo],
        ISNULL(o1.Price, 0) AS [Price],
        '' AS [Product],
        o.DateDue AS [Date_Due],
        o.Reason,
        u.UserName,
        CAST(onl.orderNo AS NVARCHAR(50)) AS [AuthNumber]
    FROM dbo.Order_No AS o WITH (READUNCOMMITTED)
    JOIN @OrderNOList AS onl ON onl.orderNo = o.Order_No
    JOIN dbo.Orders AS o1
        ON o1.Order_No = o.Order_No AND o1.ParentItemID != 0
    JOIN dbo.Products
        ON Products.Product_ID = o1.Product_ID AND Products.Product_Type = 4
    JOIN users AS u ON o.User_ID = u.User_ID
    WHERE
        o.OrderType_ID IN (22, 23)
        AND o.Filled = 1
        AND o.Process = 1
        AND o.Void = 0
        AND o.Account_ID = @Account_ID
END
